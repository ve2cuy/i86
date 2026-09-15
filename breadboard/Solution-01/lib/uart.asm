; ============================================================
; uart.asm
; Transmission serie logicielle (bit-bang, 9600 8N1) sur PA7 du
; Port A du 8255, via porta_write (voir common.asm) - partage le
; meme octet materiel que le LCD sans jamais toucher a ses bits.
;
; Garde requise (voir hardware.inc) puisque solution-01.asm inclut
; ce fichier directement. Chemins d'%include toujours relatifs a
; la racine de Solution-01 (voir hardware.inc).
; ============================================================
%ifndef UART_ASM
%define UART_ASM

%include "include/hardware.inc"
%include "lib/common.asm"

UART_MASK       equ     10000000b       ; PA7 - masque pour porta_write:
                                         ; seul ce bit du port A est
                                         ; concerne par l'UART
UART_BIT_ON     equ     10000000b       ; valeur du bit UART a l'etat "1"
UART_IDLE       equ     10000000b       ; ligne au repos (MARK) = 1

; UART_BIT_COUNT: valeur VALIDEE sur ce montage (solution-01, UART
; sur PA7 via porta_write) - mesuree par Alain a l'analyseur
; logique: periode variant entre 106 et 110us (cible 104.17us pour
; 9600 bauds), affichage terminal stable et lisible.
;
; Historique de la calibration: le modele analytique derive de
; l'ancienne mesure (105us a N=17 avec un "out" direct, puis 164us
; au meme N=17 une fois porta_write ajoute -> ~59us de surcharge
; fixe, d'ou T(N) ~= 85.8 + 4.6*N us) predisait N=4 (~104.2us), mais
; N=3 s'est avere necessaire en pratique - le modele (base sur
; seulement 2 points) sous-estimait la surcharge reelle. Le leger
; jitter observe (quelques us de variation pour le meme N) est une
; caracteristique connue du 8088: sa file d'instructions (prefetch
; queue) se remplit de facon asynchrone par rapport a l'execution,
; ce qui fait varier legerement le nombre de cycles reels d'une
; boucle dec/jnz serree - un modele purement analytique ne peut pas
; le capturer parfaitement, d'ou l'importance de mesurer sur le vrai
; materiel plutot que de se fier au calcul seul.
; Ne pas modifier sans re-mesurer.
UART_BIT_COUNT  equ     3

; ============================================================
; uart_tx_string / uart_tx_byte / uart_bit_delay
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

; uart_tx_byte: transmet AL (8N1) via porta_write, qui ne touche
; que le bit PA7 (masque UART_MASK) et preserve le reste du port A
; (donc le LCD) via la copie fantome. BX doit survivre a cet appel
; (test_segment y garde l'octet original pendant tout le cycle
; test-restauration) - meme discipline que uart_tx_hex_nibble/byte
; /word: on sauve/restaure BX ici puisqu'on utilise BL en interne.
uart_tx_byte:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     dl, al          ; DL = copie de l'octet a transmettre
        mov     bl, UART_MASK   ; masque Port A pour toute la duree de cet octet

        mov     al, 0           ; --- bit de start ---
        call    porta_write
        call    uart_bit_delay

        mov     cl, 8           ; --- 8 bits de donnees, LSB en premier ---
.bitloop:
        mov     al, dl
        and     al, 00000001b
        cmp     al, 0
        je      .bit_zero
        mov     al, UART_BIT_ON
        jmp     .send_bit
.bit_zero:
        mov     al, 0
.send_bit:
        call    porta_write
        call    uart_bit_delay

        shr     dl, 1
        dec     cl
        jnz     .bitloop

        mov     al, UART_IDLE   ; --- bit de stop ---
        call    porta_write
        call    uart_bit_delay

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; Generee par def_busy_delay (lib/common.asm) - meme motif que
; lcd_short_delai/lcd_delay/lcd_delay_long (lib/lcd.asm) et
; i2c_delay (lib/lcd_i2c.asm).
def_busy_delay uart_bit_delay, UART_BIT_COUNT

; ============================================================
; uart_tx_hex_nibble / uart_tx_hex_byte / uart_tx_hex_word
; Affichent une valeur en hexadecimal (majuscules) via l'UART.
; Detruisent AX et BX (jamais CX/DX/SI/DI/ES/BP: sans danger a
; appeler depuis test_segment ou rom_dump au milieu d'une boucle).
; Generees par def_tx_hex_nibble/byte/word (lib/common.asm) - voir
; ce fichier pour la logique partagee avec lcd_tx_hex_* et
; i2c_lcd_tx_hex_*.
; ============================================================
def_tx_hex_nibble uart_tx_hex_nibble, uart_tx_byte
def_tx_hex_byte   uart_tx_hex_byte,   uart_tx_hex_nibble
def_tx_hex_word   uart_tx_hex_word,   uart_tx_hex_byte

%endif ; UART_ASM
