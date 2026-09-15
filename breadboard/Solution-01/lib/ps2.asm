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
; cas UNIQUEMENT quand TEST_PS2 est actif (voir MASQUE_PIO dans
; include/hardware.inc, et TEST_PS2 dans solution-01.asm). Si le
; Port B est laisse en sortie (comportement par defaut), "IN
; AL,PORTB" relirait le verrou de sortie (comme PORTA dans
; lib/lcd_i2c.asm), PAS les broches - ps2_read_byte ne doit donc
; JAMAIS etre appelee en dehors d'un contexte TEST_PS2.
;
; Contrairement a l'UART (ou l'hote choisit le rythme de
; transmission), le CLAVIER est maitre de l'horloge: il genere
; CLOCK (~10-16 kHz) de facon ASYNCHRONE, quand une touche est
; pressee/relachee. Consequence: ps2_read_byte DOIT tourner sans
; interruption logicielle du debut a la fin d'une trame (aucun
; autre code n'a la main) - un front d'horloge manque a cause d'un
; traitement en cours ailleurs corromprait la lecture. Reservee a
; un contexte dedie (voir TEST_PS2 dans solution-01.asm), jamais
; appelee au milieu d'une boucle deja engagee ailleurs (ex:
; test_ram).
;
; Format d'une trame (11 bits, LSB en premier): start(0), 8 bits de
; donnees, parite IMPAIRE, stop(1). Chaque bit est stable sur DATA
; au moment du front DESCENDANT de CLOCK - c'est la que ps2_read_byte
; echantillonne.
;
; Scan Code Set 2 (defaut du clavier a la mise sous tension, aucune
; commande d'initialisation requise pour ce premier jalon): un
; "make" (touche pressee) envoie 1 octet (ou 2 pour les touches
; etendues, prefixees de 0E0h); un "break" (touche relachee) est
; prefixe de 0F0h. Pas encore traduit en ASCII ici - ps2_read_byte
; ne fait que capturer UN octet brut a la fois, voir TEST_PS2.
;
; Garde requise (voir hardware.inc) puisque solution-01.asm inclut
; ce fichier directement. Chemins d'%include toujours relatifs a
; la racine de Solution-01 (voir hardware.inc).
; ============================================================
%ifndef PS2_ASM
%define PS2_ASM

%include "include/hardware.inc"

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

%endif ; PS2_ASM
