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

; Codes retournes par ps2_get_char pour les fleches (touches etendues,
; prefixe 0E0h) - valeurs choisies dans une plage inutilisee (aucun
; caractere ASCII imprimable, ni CR/BS/ESC deja utilises par ce projet).
PS2_KEY_UP      equ     11h
PS2_KEY_DOWN    equ     12h
PS2_KEY_LEFT    equ     13h
PS2_KEY_RIGHT   equ     14h

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
; les valeurs hexa), Q (quitter l'editeur RAM), R (enregistrer+
; executer, edit_run_action), Entree (13), Retour arriere (8), Echap
; (27). Terminee par 0,0 (aucun scan code valide n'est 0). Les
; touches non listees ici (fleches - voir ps2_ext_keymap -, F1-F12,
; pave numerique, autres lettres, etc.) sont simplement ignorees par
; ps2_get_char - c'est CETTE liste blanche, pas seulement le code
; appelant, qu'il faut mettre a jour pour qu'une NOUVELLE touche soit
; un jour reconnue (bug trouve sur le materiel reel: 'R' verifiee
; partout dans edit_run_action ne faisait jamais rien, puisqu'elle
; etait absente d'ICI et donc silencieusement avalee par
; ps2_get_char avant meme d'atteindre ce code).
;
; Majuscule uniquement (pas de distinction Maj/minuscule: l'etat des
; touches Shift n'est pas suivi) - edit_ram_action/edit_run_action
; verifient donc 'Q'/'R' ET 'q'/'r' par prudence, mais seules 'Q'/'R'
; peuvent effectivement etre recues.
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
        db      015h, 'Q'       ; quitte l'editeur RAM (edit_ram_action)
        db      02Dh, 'R'       ; enregistre+execute (edit_run_action)
        db      05Ah, 13        ; Entree
        db      066h, 8         ; Retour arriere
        db      076h, 27        ; Echap
        db      0, 0            ; fin de table

; ============================================================
; ps2_ext_keymap / ps2_extended_to_char
; Meme principe que ps2_keymap/ps2_scancode_to_char, mais pour les
; scan codes ETENDUS (prefixe 0E0h - voir ps2_get_char): fleches
; uniquement pour ce projet.
; ============================================================
ps2_ext_keymap:
        db      075h, PS2_KEY_UP
        db      072h, PS2_KEY_DOWN
        db      06Bh, PS2_KEY_LEFT
        db      074h, PS2_KEY_RIGHT
        db      0, 0            ; fin de table

; ============================================================
; ps2_table_lookup
; Recherche AL dans une table (code,valeur) pointee par BX, terminee
; par 0,0 - factorise la logique commune a ps2_scancode_to_char et
; ps2_extended_to_char.
; Entree: AL = code a chercher, BX = adresse de la table.
; Sortie: AL = valeur trouvee, CF=0 si trouve, CF=1 sinon.
; ============================================================
ps2_table_lookup:
        push    dx
        mov     dl, al
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
        ret

; Entree: AL = scan code brut (make code) a chercher dans ps2_keymap.
; Sortie: AL = caractere ASCII correspondant, CF=0 si trouve, CF=1
; sinon (touche non geree par ce projet - AL indefini).
ps2_scancode_to_char:
        push    bx
        mov     bx, ps2_keymap
        call    ps2_table_lookup
        pop     bx
        ret

; Entree: AL = scan code brut ETENDU (apres le prefixe 0E0h) a
; chercher dans ps2_ext_keymap.
; Sortie: AL = code PS2_KEY_* correspondant, CF=0 si trouve, CF=1
; sinon (touche etendue non geree par ce projet - AL indefini).
ps2_extended_to_char:
        push    bx
        mov     bx, ps2_ext_keymap
        call    ps2_table_lookup
        pop     bx
        ret

; ============================================================
; ps2_get_char
; Bloque jusqu'a l'appui d'une touche RECONNUE (voir ps2_keymap pour
; les touches normales, ps2_ext_keymap pour les fleches) - ignore les
; relachements (prefixe 0F0h) en consommant correctement leur
; sequence, ainsi que les touches non reconnues (normales ou
; etendues).
; Sortie: AL = caractere ASCII de la touche pressee, OU PS2_KEY_UP/
;         DOWN/LEFT/RIGHT pour une fleche. BH = scan code PS/2 Set 2
;         BRUT de cette touche (le second octet, pour une touche
;         etendue) - ajoute pour int16h_handler (solution-01.asm),
;         qui l'expose en AH ("esprit BIOS", voir sa doc). Aucun
;         appelant existant n'utilisait BH (deja "detruit" avant ce
;         changement) - ps2_scancode_to_char/ps2_extended_to_char
;         preservent BX (push/pop), donc le sauvegarder AVANT de les
;         appeler suffit.
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
        mov     bh, al          ; BH = scan code brut (survit a l'appel
                                 ; suivant, qui preserve BX)
        call    ps2_scancode_to_char
        jc      .loop           ; touche non geree - ignore, reboucle
        ret                     ; AL = caractere reconnu, BH = scan code brut
.got_e0:
        ; --- touche etendue: le prochain octet est soit F0 (relachement
        ; etendu, encore a consommer) soit le scan code de la pression
        ; etendue elle-meme (fleche reconnue, ou ignoree sinon) ---
        call    ps2_read_byte
        cmp     al, 0F0h
        je      .got_e0_f0
        mov     bh, al          ; BH = scan code brut (etendu)
        call    ps2_extended_to_char
        jc      .loop           ; touche etendue non geree - ignore, reboucle
        ret                     ; AL = PS2_KEY_UP/DOWN/LEFT/RIGHT, BH = scan code brut
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
; ps2_read_hex_editable
; Lit CL chiffres hexadecimaux au clavier (0-9, A-F), avec echo sur
; l'UART ET le LCD parallele, et gestion du RETOUR ARRIERE: efface
; visuellement le dernier chiffre saisi (UART: BS/espace/BS: LCD:
; repositionne la case, ecrit un espace, repositionne de nouveau) et
; recule d'un chiffre. Termine des que CL chiffres valides sont
; accumules (largeur fixe - contrairement a ps2_edit_byte_value, qui
; termine sur Entree).
;
; IMPORTANT: l'appelant doit avoir positionne le curseur LCD (DDRAM)
; au DEBUT du champ juste avant l'appel (ex: via lcd_show), ET fournir
; cette meme adresse DDRAM dans AH (SANS le bit de commande 80h - ex:
; LCD_LINE1 & 07Fh, plus la longueur d'un prefixe deja affiche sur
; cette ligne), pour que le retour arriere puisse y repositionner
; precisement le curseur.
;
; Entree: CL = nombre de chiffres a lire (2 ou 4). AH = adresse DDRAM
;         de depart du champ (0-127, sans le bit de commande).
; Sortie: BX = valeur entree (chiffres accumules, MSB en premier).
; Detruit: AX, CX, DX (BX est la sortie). Jamais SI/DI/ES/BP.
;
; IMPORTANT: l'accumulateur interne vit dans SI, PAS BX - depuis que
; ps2_get_char expose le scan code brut en BH (voir son en-tete),
; BH est ecrase a CHAQUE appel, ce qui corromprait un accumulateur
; multi-chiffres loge dans BX. SI, lui, n'est jamais touche par
; ps2_get_char. Bug confirme sur le materiel reel avant ce correctif:
; saisir "0000" donnait "5000" (045h, le scan code Set 2 de '0',
; ecrasait BH -> BX=4500h apres le 1er chiffre -> shl bx,4 = 45000h,
; tronque a 16 bits = 5000h - voir Directives.md).
; ============================================================
ps2_read_hex_editable:
        push    si              ; SI = accumulateur interne - restaure la
                                 ; valeur d'origine de l'appelant avant le
                                 ; retour (BX reste la SORTIE documentee)
        xor     si, si
        mov     ch, cl          ; CH = nombre TOTAL de chiffres a lire (fixe)
        xor     dh, dh          ; DH = nombre de chiffres saisis jusqu'ici
.next_key:
        call    ps2_get_char
        cmp     al, 8           ; retour arriere ?
        je      .backspace
        call    ps2_hex_digit_value
        jc      .next_key       ; touche non geree (Entree, Echap...) - ignore
        cmp     dh, ch
        jae     .next_key       ; deja le nombre de chiffres voulu - ignore
        mov     dl, al          ; DL = valeur de ce chiffre (0-15), survit
                                 ; aux 2 echos ci-dessous
        mov     cl, 4
        shl     si, cl
        push    dx              ; DH(compteur)/DL(valeur) sauvegardes ensemble
        mov     dh, 0           ; DH=0 temporairement (les 4 bits bas de SI
        add     si, dx          ; sont a 0 apres le decalage - addition = OR)
        pop     dx              ; restaure DH(compteur)/DL(valeur)
        mov     al, dl
        call    uart_tx_hex_nibble
        mov     al, dl
        call    lcd_tx_hex_nibble
        inc     dh
        cmp     dh, ch
        jb      .next_key
        mov     bx, si          ; BX = valeur finale (sortie documentee)
        pop     si              ; restaure le SI de l'appelant
        ret
.backspace:
        cmp     dh, 0
        je      .next_key       ; rien a effacer - ignore
        dec     dh
        mov     cl, 4           ; efface le dernier chiffre de la valeur
        shr     si, cl          ; accumulee (division par 16)
        mov     al, 8           ; efface visuellement sur l'UART (backspace,
        call    uart_tx_byte    ; espace, backspace)
        mov     al, ' '
        call    uart_tx_byte
        mov     al, 8
        call    uart_tx_byte
        mov     al, ah          ; --- efface visuellement sur le LCD:
        add     al, dh          ; repositionne sur la case effacee, ecrit
        or      al, 80h         ; un espace, repositionne de nouveau (le
        call    lcd_command     ; prochain chiffre tape doit ecraser cette
        mov     al, ' '         ; meme case, pas la suivante) ---
        call    lcd_data
        mov     al, ah
        add     al, dh
        or      al, 80h
        call    lcd_command
        jmp     .next_key

; ============================================================
; ps2_edit_byte_value
; Compose une nouvelle valeur d'octet (0-2 chiffres hexa) au clavier,
; avec echo UART+LCD et retour arriere (meme mecanique que
; ps2_read_hex_editable), mais attend la touche ENTREE pour terminer
; plutot que de completer automatiquement a un nombre fixe de
; chiffres - permet de ne taper qu'1 chiffre (ex: 'F'+Entree = 0Fh).
;
; Le PREMIER caractere doit etre fourni par l'appelant en AL (deja lu
; via ps2_get_char - evite de le relire/perdre si l'appelant a du le
; lire pour decider d'appeler cette routine, voir edit_ram_action):
; s'il n'est ni Entree, ni Retour arriere, ni un chiffre hexa, il est
; simplement ignore (comme les touches suivantes) et la lecture
; continue normalement.
;
; Entree: AL = premier caractere deja lu par l'appelant. AH = adresse
;         DDRAM de la cellule (0-127, sans le bit de commande).
; Sortie: BX = valeur composee. CF=0 si au moins un chiffre a ete
;         tape (valeur a ecrire), CF=1 si Entree a ete pressee sans
;         aucune saisie (BX indefini - rien a ecrire).
; Detruit: AX, CX, DX (BX est la sortie). Jamais SI/DI/ES/BP.
;
; IMPORTANT: l'accumulateur interne vit dans SI, PAS BX - meme raison
; et meme correctif que ps2_read_hex_editable (voir son en-tete):
; ps2_get_char ecrase BH (scan code brut) a chaque appel, ce qui
; corromprait un accumulateur loge dans BX.
; ============================================================
ps2_edit_byte_value:
        push    si              ; SI = accumulateur interne - restaure la
                                 ; valeur d'origine de l'appelant avant
                                 ; chaque retour (BX reste la SORTIE
                                 ; documentee)
        xor     si, si
        xor     dh, dh          ; DH = nombre de chiffres saisis (0-2)
        jmp     .have_key       ; traite d'abord le caractere deja lu par
                                 ; l'appelant, avant de lire les suivants
.next_key:
        call    ps2_get_char
.have_key:
        cmp     al, 13          ; Entree ?
        je      .commit
        cmp     al, 8           ; retour arriere ?
        je      .backspace
        call    ps2_hex_digit_value
        jc      .next_key       ; touche non geree - ignore
        cmp     dh, 2
        jae     .next_key       ; deja 2 chiffres - ignore
        mov     dl, al
        mov     cl, 4
        shl     si, cl
        push    dx              ; DH(compteur)/DL(valeur) sauvegardes ensemble
        mov     dh, 0           ; DH=0 temporairement (les 4 bits bas de SI
        add     si, dx          ; sont a 0 apres le decalage - addition = OR)
        pop     dx              ; restaure DH(compteur)/DL(valeur)
        mov     al, dl
        call    uart_tx_hex_nibble
        mov     al, dl
        call    lcd_tx_hex_nibble
        inc     dh
        jmp     .next_key
.backspace:
        cmp     dh, 0
        je      .next_key
        dec     dh
        mov     cl, 4
        shr     si, cl
        mov     al, 8
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte
        mov     al, 8
        call    uart_tx_byte
        mov     al, ah
        add     al, dh
        or      al, 80h
        call    lcd_command
        mov     al, ' '
        call    lcd_data
        mov     al, ah
        add     al, dh
        or      al, 80h
        call    lcd_command
        jmp     .next_key
.commit:
        cmp     dh, 0
        je      .empty
        mov     bx, si          ; BX = valeur finale (sortie documentee)
        pop     si              ; restaure le SI de l'appelant
        clc
        ret
.empty:
        pop     si              ; restaure le SI de l'appelant (BX indefini,
                                 ; comme documente - rien a ecrire)
        stc
        ret

%endif ; PS2_ASM
