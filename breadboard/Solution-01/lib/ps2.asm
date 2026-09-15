; ============================================================
; ps2.asm
; Lecture d'un clavier PS/2 en polling pur (AUCUNE interruption -
; le projet n'en utilise pas encore, voir Directives.md), via le
; Port B du 8255:
;   PB0 = CLOCK
;   PB1 = DATA
; Necessite des resistances de tirage externes (~4,7-10 kOhm vers
; +5V) sur CLOCK/DATA si le cable/clavier n'en fournit pas deja
; (lignes open-drain, comme l'I2C).
;
; IMPORTANT: le Port B doit etre configure en ENTREE pour que
; "IN AL,PORTB" lise l'etat electrique reel des broches - c'est le
; cas EN PERMANENCE depuis que le menu interactif en depend (voir
; MASQUE_PIO dans include/hardware.inc). Si le Port B etait laisse
; en sortie, "IN AL,PORTB" relirait le verrou de sortie (comme
; PORTA dans lib/lcd_i2c.asm), PAS les broches.
;
; Contrairement a l'UART (ou l'hote choisit le rythme de
; transmission), le CLAVIER est maitre de l'horloge: il genere
; CLOCK (~10-16 kHz) de facon ASYNCHRONE, quand une touche est
; pressee/relachee. Consequence: ps2_read_byte (et tout ce qui en
; depend: ps2_get_char, ps2_read_hex) DOIT tourner sans interruption
; logicielle du debut a la fin d'une trame (aucun autre code n'a la
; main) - un front d'horloge manque a cause d'un traitement en cours
; ailleurs corromprait la lecture. Jamais appelee au milieu d'une
; boucle deja engagee ailleurs (ex: test_ram).
;
; Format d'une trame (11 bits, LSB en premier): start(0), 8 bits de
; donnees, parite IMPAIRE, stop(1). Chaque bit est stable sur DATA
; au moment du front DESCENDANT de CLOCK - c'est la que ps2_read_byte
; echantillonne.
;
; Scan Code Set 2 (defaut du clavier a la mise sous tension, aucune
; commande d'initialisation requise): un "make" (touche pressee)
; envoie 1 octet (ou 2 pour les touches etendues, prefixees de
; 0E0h); un "break" (touche relachee) est prefixe de 0F0h.
; ps2_get_char gere ces prefixes (voir plus bas) et ne retourne que
; les caracteres reconnus issus d'un appui (jamais d'un relachement).
;
; Garde requise (voir hardware.inc) puisque solution-01.asm inclut
; ce fichier directement. Chemins d'%include toujours relatifs a
; la racine de Solution-01 (voir hardware.inc).
; ============================================================
%ifndef PS2_ASM
%define PS2_ASM

%include "include/hardware.inc"
%include "lib/lcd.asm"          ; reutilise lcd_tx_hex_nibble (echo saisie hexa)
%include "lib/uart.asm"         ; reutilise uart_tx_hex_nibble (echo saisie hexa)

PS2_CLOCK       equ     00000001b       ; PB0
PS2_DATA        equ     00000010b       ; PB1

; ============================================================
; ps2_wait_falling_edge
; Attend que CLOCK (PB0) soit haut puis redescende (front
; descendant) - utilisee pour synchroniser chaque bit d'une trame
; (le bit de start est detecte separement par ps2_read_byte, avec
; la meme logique).
; Sortie: AL = etat du Port B AU MOMENT du front (contient DATA).
; ============================================================
ps2_wait_falling_edge:
.wait_high:
        in      al, PORTB
        test    al, PS2_CLOCK
        jz      .wait_high
.wait_low:
        in      al, PORTB
        test    al, PS2_CLOCK
        jnz     .wait_low
        ret

; ============================================================
; ps2_read_byte
; Lit UNE trame PS/2 complete (11 bits), bloque jusqu'a reception.
; Voir l'en-tete du fichier pour le format et les contraintes de
; timing (aucune interruption, contexte dedie uniquement).
;
; Sortie: AL = octet de donnees recu (scan code brut, Set 2).
;         CF = 1 si erreur (parite impaire invalide OU bit stop
;         different de 1) - AL est quand meme retourne, pour
;         diagnostic (voir TEST_PS2).
; Detruit: AX, BX, CX, DX. Jamais SI/DI/ES/BP.
; ============================================================
ps2_read_byte:
        push    bx
        push    cx
        push    dx

        ; --- attend l'etat de repos (CLOCK haut) avant de commencer,
        ; pour ne jamais se synchroniser au milieu d'une trame deja
        ; en cours ---
.wait_idle:
        in      al, PORTB
        test    al, PS2_CLOCK
        jz      .wait_idle

        ; --- front descendant du bit de start (valeur ignoree - le
        ; bit de stop, verifie plus bas, suffit a detecter une trame
        ; corrompue) ---
.wait_start:
        in      al, PORTB
        test    al, PS2_CLOCK
        jnz     .wait_start

        xor     bh, bh          ; BH = octet de donnees en construction
        mov     bl, 1           ; BL = masque du bit courant (LSB en premier)
        mov     cl, 8           ; CL = compteur de bits de donnees restants
        xor     dh, dh          ; DH = parite courante (XOR des bits vus,
                                 ; donnees puis parite - voir plus bas)

.bit_loop:
        call    ps2_wait_falling_edge
        test    al, PS2_DATA
        jz      .bit_zero
        or      bh, bl          ; pose ce bit dans l'octet
        xor     dh, 1           ; met a jour la parite courante
.bit_zero:
        shl     bl, 1           ; masque -> bit suivant
        dec     cl
        jnz     .bit_loop

        ; --- bit de parite: parite IMPAIRE correcte si le XOR total
        ; (8 bits de donnees + ce bit) vaut 1 ---
        call    ps2_wait_falling_edge
        test    al, PS2_DATA
        jz      .parity_zero
        xor     dh, 1
.parity_zero:

        ; --- bit de stop (doit etre 1) ---
        call    ps2_wait_falling_edge
        mov     cl, 1           ; CL = 1 si le bit de stop est correct
                                 ; (les 8 bits de donnees sont deja traites,
                                 ; CL est reutilise sans risque)
        test    al, PS2_DATA
        jnz     .stop_ok
        xor     cl, cl
.stop_ok:

        cmp     dh, 1
        jne     .bad_frame
        cmp     cl, 1
        jne     .bad_frame
        clc                     ; trame correcte: CF=0
        jmp     .frame_done
.bad_frame:
        stc                     ; erreur (parite ou stop invalide): CF=1
.frame_done:
        mov     al, bh          ; AL = octet de donnees recu, dans tous les cas

        pop     dx
        pop     cx
        pop     bx
        ret

; ============================================================
; ps2_keymap / ps2_scancode_to_char
; Table (scan code Set 2, caractere ASCII) pour les touches utiles
; au menu/a la saisie hexadecimale: chiffres 0-9, lettres A-F (pour
; les valeurs hexa), Entree (13), Retour arriere (8), Echap (27).
; Terminee par 0,0 (aucun scan code valide n'est 0). Les touches non
; listees ici (fleches, F1-F12, pave numerique, etc.) sont
; simplement ignorees par ps2_get_char.
; ============================================================
ps2_keymap:
        db      016h, '1'
        db      01Eh, '2'
        db      026h, '3'
        db      025h, '4'
        db      02Eh, '5'
        db      036h, '6'
        db      03Dh, '7'
        db      03Eh, '8'
        db      046h, '9'
        db      045h, '0'
        db      01Ch, 'A'
        db      032h, 'B'
        db      021h, 'C'
        db      023h, 'D'
        db      024h, 'E'
        db      02Bh, 'F'
        db      05Ah, 13        ; Entree
        db      066h, 8         ; Retour arriere
        db      076h, 27        ; Echap
        db      0, 0            ; fin de table

; Entree: AL = scan code brut (make code) a chercher dans ps2_keymap.
; Sortie: AL = caractere ASCII correspondant, CF=0 si trouve, CF=1
; sinon (touche non geree par ce projet - AL indefini).
ps2_scancode_to_char:
        push    bx
        push    dx
        mov     dl, al
        mov     bx, ps2_keymap
.scan:
        mov     al, [bx]
        cmp     al, 0
        je      .not_found
        cmp     al, dl
        je      .found
        add     bx, 2
        jmp     .scan
.found:
        mov     al, [bx+1]
        clc
        jmp     .done
.not_found:
        stc
.done:
        pop     dx
        pop     bx
        ret

; ============================================================
; ps2_get_char
; Bloque jusqu'a l'appui d'une touche RECONNUE (voir ps2_keymap) -
; ignore les relachements (prefixe 0F0h) et les touches etendues
; (prefixe 0E0h, ex: fleches) en consommant correctement leurs
; sequences, ainsi que les touches non reconnues.
; Sortie: AL = caractere ASCII de la touche pressee.
; Detruit: AX, BX, CX, DX. Jamais SI/DI/ES/BP.
; ============================================================
ps2_get_char:
.loop:
        call    ps2_read_byte
        cmp     al, 0E0h
        je      .got_e0
        cmp     al, 0F0h
        je      .got_f0
        ; --- scan code de pression (make code) normal ---
        call    ps2_scancode_to_char
        jc      .loop           ; touche non geree - ignore, reboucle
        ret                     ; AL = caractere reconnu
.got_e0:
        ; --- touche etendue: le prochain octet est soit F0 (relachement
        ; etendu, encore a consommer) soit le scan code de la pression
        ; etendue elle-meme (ignoree - non geree par ce projet) ---
        call    ps2_read_byte
        cmp     al, 0F0h
        je      .got_e0_f0
        jmp     .loop
.got_e0_f0:
        call    ps2_read_byte   ; consomme le scan code du relachement etendu
        jmp     .loop
.got_f0:
        call    ps2_read_byte   ; consomme le scan code du relachement
        jmp     .loop

; ============================================================
; ps2_hex_digit_value
; Entree: AL = caractere ASCII. Sortie: AL = valeur 0-15, CF=0 si
; '0'-'9' ou 'A'-'F' (majuscule uniquement - ps2_keymap n'emet que
; des majuscules), CF=1 sinon (AL indefini).
; ============================================================
ps2_hex_digit_value:
        cmp     al, '0'
        jb      .invalid
        cmp     al, '9'
        jbe     .digit
        cmp     al, 'A'
        jb      .invalid
        cmp     al, 'F'
        ja      .invalid
        sub     al, 'A'
        add     al, 10
        clc
        ret
.digit:
        sub     al, '0'
        clc
        ret
.invalid:
        stc
        ret

; ============================================================
; ps2_read_hex
; Lit CL chiffres hexadecimaux au clavier (0-9, A-F), avec echo de
; chaque chiffre sur l'UART ET le LCD parallele (DDRAM positionnee
; par l'appelant avant l'appel - voir edit_ram_action). Ignore les
; touches non-hexadecimales (Entree, Echap...) - PAS de gestion du
; retour arriere pour ce premier jalon (voir Directives.md): en cas
; d'erreur de saisie, recommencer l'operation depuis le menu.
; Entree: CL = nombre de chiffres a lire (2 ou 4).
; Sortie: BX = valeur entree (chiffres accumules, MSB en premier).
; Detruit: AX, CX, DX (BX est la sortie). Jamais SI/DI/ES/BP.
; ============================================================
ps2_read_hex:
        xor     bx, bx
        mov     dh, cl          ; DH = nombre de chiffres restants (copie de
                                 ; l'entree CL - CX est ensuite libre d'etre
                                 ; detruit, y compris par les 2 echos hexa)
.next_digit:
        call    ps2_get_char
        call    ps2_hex_digit_value
        jc      .next_digit     ; pas un chiffre hexa - ignore, reboucle
        mov     dl, al          ; DL = valeur de ce chiffre (0-15), survit
                                 ; aux 2 echos ci-dessous
        mov     cl, 4
        shl     bx, cl
        or      bl, dl
        mov     al, dl
        call    uart_tx_hex_nibble
        mov     al, dl
        call    lcd_tx_hex_nibble
        dec     dh
        jnz     .next_digit
        ret

%endif ; PS2_ASM
