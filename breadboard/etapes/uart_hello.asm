BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; uart_hello.asm
; ------------------------------------------------------------
; Reproduit le protocole UART (8N1, 9600 bauds) en "bit-banging"
; sur UN bit du port 10h (broche TX). Emission seule - comme
; pour l'I2C, ce montage n'a aucun moyen de relire une broche,
; donc pas de reception possible avec cette approche.
;
; Cablage: bit0 du port 10h -> TX (a relier a l'entree RX d'un
; adaptateur USB-serie, ex: FTDI/CP2102, avec une masse commune).
; Au repos (MARK), la ligne est a 1.
;
; Format 8N1: 1 bit de start (0), 8 bits de donnees (LSB en
; premier), pas de parite, 1 bit de stop (1).
; ------------------------------------------------------------
STACK_SEG       equ     1000h

UART_TX         equ     00000001b       ; bit0
UART_IDLE       equ     00000001b       ; ligne au repos (MARK) = 1

; ------------------------------------------------------------
; Delai d'UN bit a 9600 bauds = 1/9600 s = 104.17 us.
;
; Point de depart pour la calibration: on a mesure sur CE MEME
; montage (via analyseur logique, pendant le debogage du LCD)
; qu'une boucle DEC/JNZ de 32 iterations (lcd_short_delai) donne
; une duree reelle d'environ 153us pour l'ensemble de la fonction
; (boucle + overhead d'appel). Ca donne un ordre de grandeur
; d'environ 4.5-4.8us par iteration sur ce materiel - TRES
; different de ce qu'un calcul theorique a 4,77 MHz donnerait,
; ce qui confirme (comme partout ailleurs dans ce projet) que le
; timing reel de ce montage est nettement plus lent que le calcul
; theorique.
;
; Avec ~4.78us/iteration, 104.17us / 4.78us =~ 22 iterations.
;
; ATTENTION: la tolerance habituelle d'un recepteur UART n'est
; que d'environ +/-2-3% - BEAUCOUP plus stricte que tout ce qu'on
; a fait jusqu'ici dans ce projet (LCD, I2C, etc. toleraient de
; grandes marges). Cette valeur de 22 est un POINT DE DEPART, pas
; une valeur fiable telle quelle: MESURE la duree reelle d'un bit
; avec l'analyseur logique une fois flashe, puis ajuste
; UART_BIT_COUNT proportionnellement (ex: si un bit dure 115us
; au lieu de 104.17us mesures, reduit legerement la constante).
; ------------------------------------------------------------
UART_BIT_COUNT  equ     22

start:
        cli
        mov     ax, STACK_SEG
        mov     ss, ax          ; SS = 1000h -> pile en fin de RAM (128K)
        mov     sp, 0000h
        sti

        mov     ax, cs
        mov     ds, ax          ; DS = CS: lit le message stocke dans la ROM

        mov     al, UART_IDLE
        out     10h, al         ; ligne au repos des le debut (evite un etat
                                 ; indetermine avant le premier envoi)

.ici:
        mov     si, msg
        call    uart_tx_string

        mov     cx, 1000        ; pause d'1 seconde entre chaque envoi
        call    delay_ms

        jmp     .ici            ; reboucle indefiniment

; ============================================================
; uart_tx_string
; Transmet une chaine terminee par 00h, un octet a la fois.
; Entree: DS:SI = adresse de la chaine.
; ============================================================
uart_tx_string:
        push    ax
        push    si
.next_char:
        mov     al, [si]
        cmp     al, 0
        je      .done
        call    uart_tx_byte
        inc     si
        jmp     .next_char
.done:
        pop     si
        pop     ax
        ret

; ============================================================
; uart_tx_byte
; Transmet UN octet en 8N1: bit de start (0), 8 bits de donnees
; (LSB en premier), bit de stop (1).
; Entree: AL = octet a transmettre.
; ============================================================
uart_tx_byte:
        push    ax
        push    cx
        push    dx
        mov     dl, al          ; DL = copie de l'octet a transmettre

        ; --- bit de start ---
        mov     al, 0
        out     10h, al
        call    uart_bit_delay

        ; --- 8 bits de donnees, LSB en premier ---
        mov     cl, 8
.bitloop:
        mov     al, dl
        and     al, 00000001b   ; teste le bit de poids faible
        cmp     al, 0
        je      .bit_zero
        mov     al, UART_TX
        jmp     .send_bit
.bit_zero:
        mov     al, 0
.send_bit:
        out     10h, al
        call    uart_bit_delay

        shr     dl, 1           ; bit suivant (SHR reg,1 - seul decalage
                                 ; disponible sur un vrai 8086/8088)
        dec     cl
        jnz     .bitloop

        ; --- bit de stop ---
        mov     al, UART_IDLE
        out     10h, al
        call    uart_bit_delay

        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; uart_bit_delay
; Duree d'UN bit UART (voir note de calibration en tete de
; fichier). Ajuster UART_BIT_COUNT si necessaire.
; ============================================================
uart_bit_delay:
        push    bx
        mov     bx, UART_BIT_COUNT
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

; ============================================================
; delay_ms
; Delai en millisecondes (voir led_walk.asm pour la meme routine
; et son explication complete). Entree: CX = nombre de ms.
; ============================================================
INNER_MS        equ     265     ; ~1 ms a 4,77 MHz (approximatif)

delay_ms:
        push    bx
        push    cx
.outer:
        mov     bx, INNER_MS
.inner:
        dec     bx
        jnz     .inner
        loop    .outer
        pop     cx
        pop     bx
        ret

; ---- message -------------------------------------------------
msg:            db      'Hello World', 13, 10, 0    ; CR LF pour un terminal

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
