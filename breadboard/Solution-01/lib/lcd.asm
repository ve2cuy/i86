; ============================================================
; lcd.asm
; Toutes les procedures d'affichage LCD (HD44780, 4 bits, Port A
; du 8255, partage avec l'UART sur PA7 via porta_write - voir
; common.asm). Cablage: PA0-PA3 -> D4-D7, PA4 -> RS, PA6 -> E,
; R/W du LCD a la masse. Afficheur 4x20.
;
; Garde requise (voir hardware.inc) puisque solution-01.asm inclut
; ce fichier directement. Chemins d'%include toujours relatifs a
; la racine de Solution-01 (voir hardware.inc).
; ============================================================
%ifndef LCD_ASM
%define LCD_ASM

%include "include/hardware.inc"
%include "lib/common.asm"

LCD_RS          equ     00010000b       ; bit4
LCD_E           equ     01000000b       ; bit6
LCD_E_MASK_OFF  equ     10111111b       ; pour effacer le bit E (AND, local a AL)
LCD_STROBE_MASK equ     01011111b       ; bits 0-4 et 6 (D4-D7,RS,E) - PAS bit7 (UART)

; ============================================================
; lcd_init
; Sequence d'initialisation standard HD44780 en mode 4 bits.
; ============================================================
lcd_init:
        push    ax

        call    lcd_powerup_delay      ; >= 15-40ms apres mise sous tension

        mov     al, 0011b
        call    lcd_strobe
        call    lcd_delay_long         ; >= 4.1ms

        mov     al, 0011b
        call    lcd_strobe
        call    lcd_delay              ; >= 100us

        mov     al, 0011b
        call    lcd_strobe
        call    lcd_delay

        mov     al, 0010b              ; bascule reellement en mode 4 bits
        call    lcd_strobe
        call    lcd_delay

        ; A partir d'ici, le LCD attend 2 quartets (fort puis faible) par
        ; octet: on peut utiliser lcd_command/lcd_data normalement.
        mov     al, 00101000b          ; Function Set: 4 bits, 2 lignes, police 5x8
        call    lcd_command

        mov     al, 00001100b          ; Display ON, curseur OFF, clignotement OFF
        call    lcd_command

        mov     al, 00000110b          ; Entry Mode: incremente, pas de decalage
        call    lcd_command

        mov     al, 00000001b          ; Clear Display
        call    lcd_command
        call    lcd_delay_long         ; Clear Display est plus lent (>= 1.52ms)

        pop     ax
        ret

; ============================================================
; lcd_command / lcd_data
; Envoient un octet complet au LCD en 2 quartets (fort puis
; faible). lcd_command: RS=0. lcd_data: RS=1 (caractere).
; Entree: AL = octet a envoyer. CX est utilise en interne (et
; restaure) - sans danger a appeler depuis test_segment.
; ============================================================
lcd_command:
        push    ax
        push    cx

        mov     ch, al
        mov     al, ch
        mov     cl, 4
        shr     al, cl          ; get the high nibble (quartet fort)
        and     al, 00001111b   ; quartet fort -> bits0-3 (RS=0: rien a ajouter)
        call    lcd_strobe

        mov     al, ch
        and     al, 00001111b   ; quartet faible
        call    lcd_strobe

        pop     cx
        pop     ax
        call    lcd_delay
        ret

lcd_data:
        push    ax
        push    cx
        mov     ch, al
        mov     cl, 4

        mov     al, ch
        shr     al, cl
        and     al, 00001111b
        or      al, LCD_RS      ; RS=1: c'est une donnee (caractere)
        call    lcd_strobe

        mov     al, ch
        and     al, 00001111b
        or      al, LCD_RS
        call    lcd_strobe

        pop     cx
        pop     ax
        call    lcd_delay
        ret

; ============================================================
; lcd_strobe
; Envoie UN quartet deja pret. Genere l'impulsion E (front
; descendant = capture reelle par le LCD). Passe par porta_write
; (masque LCD_STROBE_MASK) au lieu d'un "out" direct, pour ne
; jamais toucher au bit UART (PA7) du port A.
; Entree: AL = quartet + RS (E et R/W a 0)
; ============================================================
lcd_strobe:
        push    ax
        push    bx              ; preserve le BX de l'appelant (ex: test_segment y
                                 ; garde l'octet original pendant tout le cycle
                                 ; test-restauration) - meme discipline que
                                 ; uart_tx_hex_nibble/byte/word, necessaire depuis
                                 ; que BL sert de masque pour porta_write
        mov     bl, LCD_STROBE_MASK
        call    porta_write     ; pose RS + le quartet, E=0 (etat de repos)
        nop                     ; attend un peu avant de lever E (front montant)
        nop
        nop
        or      al, LCD_E       ; E=1
        call    porta_write
        call    lcd_short_delai ; largeur d'impulsion E (>= ~450ns, tres large marge)
        and     al, LCD_E_MASK_OFF  ; E=0 -> front descendant: le LCD capture ICI
        call    porta_write
        call    lcd_short_delai
        pop     bx
        pop     ax
        ret

; ============================================================
; lcd_print
; Affiche une chaine terminee par 00h (PAS de padding - le
; texte doit deja avoir la largeur voulue). Entree: DS:SI.
; ============================================================
lcd_print:
        push    ax
        push    si
.next_char:
        mov     al, [si]
        cmp     al, 0
        je      .done
        call    lcd_data
        inc     si
        jmp     .next_char
.done:
        pop     si
        pop     ax
        ret

; ============================================================
; lcd_line1 / lcd_line2 / lcd_line3 / lcd_line4
; Positionnement DDRAM pour un afficheur 4x20: la ligne 3 est en
; fait la suite de la ligne 1 en memoire interne (00h puis 14h), et
; la ligne 4 la suite de la ligne 2 (40h puis 54h) - convention
; standard ("type A") des afficheurs 20x4 bases sur le HD44780.
; ============================================================
lcd_line1:
        push    ax
        mov     al, 10000000b   ; Set DDRAM Address = 80h | 00h
        call    lcd_command
        pop     ax
        ret

lcd_line2:
        push    ax
        mov     al, 11000000b   ; Set DDRAM Address = 80h | 40h
        call    lcd_command
        pop     ax
        ret

lcd_line3:
        push    ax
        mov     al, 10010100b   ; Set DDRAM Address = 80h | 14h
        call    lcd_command
        pop     ax
        ret

lcd_line4:
        push    ax
        mov     al, 11010100b   ; Set DDRAM Address = 80h | 54h
        call    lcd_command
        pop     ax
        ret

; ============================================================
; lcd_show_line1 / lcd_show_line2 / lcd_show_line3 / lcd_show_line4
; ============================================================
lcd_show_line1:
        call    lcd_line1
        call    lcd_print
        ret

lcd_show_line2:
        call    lcd_line2
        call    lcd_print
        ret

lcd_show_line3:
        call    lcd_line3
        call    lcd_print
        ret

lcd_show_line4:
        call    lcd_line4
        call    lcd_print
        ret

; ============================================================
; lcd_tx_hex_nibble / lcd_tx_hex_byte / lcd_tx_hex_word
; ============================================================
lcd_tx_hex_nibble:
        push    bx
        and     al, 0Fh
        mov     bl, al
        xor     bh, bh
        mov     al, [hex_table + bx]
        call    lcd_data
        pop     bx
        ret

lcd_tx_hex_byte:
        push    bx
        mov     bl, al
        mov     al, bl
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        call    lcd_tx_hex_nibble
        mov     al, bl
        call    lcd_tx_hex_nibble
        pop     bx
        ret

lcd_tx_hex_word:
        push    bx
        mov     bx, ax
        mov     al, bh
        call    lcd_tx_hex_byte
        mov     al, bl
        call    lcd_tx_hex_byte
        pop     bx
        ret

; ============================================================
; lcd_tx_dec3
; Affiche AX (0-999) en decimal, TOUJOURS 3 chiffres avec des
; zeros de tete (ex: 7 -> "007", 257 -> "257"). Detruit AX/BX/CX/
; DX - jamais SI/DI/ES/BP (meme discipline que les routines hex).
; Utilise pour les compteurs de l'etape 2 (blocs/defauts, 0-127) et
; de l'etape 3 (numero de ligne, 1-257) sur le LCD 4x20.
; ============================================================
lcd_tx_dec3:
        push    bx
        push    cx
        push    dx

        xor     dx, dx
        mov     bx, 100
        div     bx              ; AX = centaines, DX = reste (0-99)
        mov     cl, al          ; CL = chiffre des centaines

        mov     ax, dx
        xor     dx, dx
        mov     bx, 10
        div     bx              ; AX = dizaines, DX = unites
        mov     ch, dl          ; CH = chiffre des unites
        mov     bh, al          ; BH = chiffre des dizaines

        mov     al, cl
        add     al, '0'
        call    lcd_data        ; centaines
        mov     al, bh
        add     al, '0'
        call    lcd_data        ; dizaines
        mov     al, ch
        add     al, '0'
        call    lcd_data        ; unites

        pop     dx
        pop     cx
        pop     bx
        ret

; ============================================================
; Delais LCD
; Calibration: meme motif d'instruction (dec bx / jnz) que
; delay_ms_proc (voir lib/utils.asm, INNER_MS=265 pour ~1ms a
; 4,77 MHz) -> 1 iteration ~ 1000/265 ~ 3,77 us.
;
; Valeurs resserrees au plus proche du minimum requis par le
; HD44780 (datasheet, fOSC=270kHz), avec une legere marge de
; securite (facteur indique par delai) pour absorber la tolerance
; des afficheurs/horloges reels sur breadboard - au lieu des tres
; grandes marges (jusqu'a ~50x) utilisees avant. Si l'affichage
; devient instable sur le materiel reel, augmenter la marge la
; plus serree en premier (lcd_delay, ~1,75x).
; ============================================================
lcd_short_delai:        ; impulsion E (>=450ns) / cycle E (>=1us) - ~7,5us (~7-16x le minimum)
        push    bx
        mov     bx, 0002h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_delay:               ; execution normale d'une commande/donnee (37-43us typique) - ~75us (~1,75x)
        push    bx
        mov     bx, 0014h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_delay_long:          ; Clear/Home (>=1,52ms) et etapes du reveil 4 bits (>=4,1ms, la plus contraignante) - ~5,8ms (~1,4x)
        push    bx
        mov     bx, 0600h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_powerup_delay:       ; >= 15-40ms apres mise sous tension - ~35ms (6x lcd_delay_long, ~2,3x le minimum de 15ms)
        push    cx
        mov     cx, 0006h
.rep:
        push    cx
        call    lcd_delay_long
        pop     cx
        loop    .rep
        pop     cx
        ret

%endif ; LCD_ASM
