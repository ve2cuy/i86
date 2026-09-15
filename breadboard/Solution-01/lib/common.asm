; ============================================================
; common.asm
; Code et donnees partages entre lcd.asm et uart.asm: porta_write
; (le seul point d'acces en ecriture au Port A du 8255, pour que le
; LCD et l'UART puissent cohabiter sur le meme octet sans se marcher
; sur les pieds - voir l'en-tete de solution-01.asm) et hex_table
; (utilisee par lcd_tx_hex_* ET uart_tx_hex_*).
;
; Inclus par lib/lcd.asm, lib/uart.asm ET solution-01.asm - garde
; requise pour eviter les symboles dupliques. Voir hardware.inc
; pour la regle des chemins d'%include (toujours relatifs a la
; racine de Solution-01).
; ============================================================
%ifndef COMMON_ASM
%define COMMON_ASM

%include "include/hardware.inc"

; ============================================================
; porta_write
; Ecrit sur le port A du 8255 en preservant tous les bits SAUF
; ceux indiques par le masque BL (lecture-modification-ecriture
; via une copie fantome en RAM, puisque le 8255 en mode 0 ne
; permet pas d'adresser un seul bit du port A - contrairement au
; port C, voir solution-02.asm). La copie fantome vit dans la zone
; deja reservee a la pile (PORTA_SHADOW_OFF, segment VAR_SEG) -
; largement hors de portee d'une pile qui, avec ce programme,
; n'utilise jamais plus de quelques dizaines d'octets.
;
; Entree: AL = nouveaux bits (seuls ceux couverts par BL comptent,
;         le reste de AL est ignore), BL = masque (1 = ce bit vient
;         de AL, 0 = ce bit est preserve depuis le dernier appel)
; Sortie: AL et BL inchanges (utile pour lcd_strobe, qui rappelle
;         porta_write plusieurs fois de suite avec le meme masque)
; ============================================================
porta_write:
        push    ax
        push    cx
        push    dx
        push    es
        push    di

        mov     cl, al          ; CL = nouveaux bits (bruts, non masques)

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, PORTA_SHADOW_OFF
        mov     dl, [es:di]     ; DL = copie fantome actuelle

        mov     ah, bl          ; AH = masque
        not     ah              ; AH = ~masque (bits a preserver)
        and     dl, ah          ; DL = etat precedent, bits du masque effaces

        mov     al, cl          ; AL = nouveaux bits (bruts)
        and     al, bl          ; AL = seulement les bits couverts par le masque
        or      al, dl          ; AL = combinaison finale

        mov     [es:di], al     ; met a jour la copie fantome
        out     PORTA, al       ; ecrit sur le port physique

        pop     di
        pop     es
        pop     dx
        pop     cx
        pop     ax
        ret

; --- table de conversion hexadecimale (partagee LCD/UART) -------------
hex_table:              db      '0123456789ABCDEF'

; ============================================================
; def_tx_hex_nibble / def_tx_hex_byte / def_tx_hex_word
; Generateurs de procedures d'affichage hexadecimal (majuscules, via
; hex_table ci-dessus). La MEME logique etait auparavant dupliquee 3
; fois (LCD parallele, UART, LCD I2C), ne differant que par la
; procedure appelee pour emettre une unite (caractere pour nibble,
; nibble-proc pour byte, byte-proc pour word). Chaque macro GENERE
; une procedure complete (label + code + ret).
;
; Usage (voir lib/lcd.asm, lib/uart.asm, lib/lcd_i2c.asm):
;   def_tx_hex_nibble lcd_tx_hex_nibble, lcd_data
;   def_tx_hex_byte   lcd_tx_hex_byte,   lcd_tx_hex_nibble
;   def_tx_hex_word   lcd_tx_hex_word,   lcd_tx_hex_byte
;
; %1 = nom de la procedure a definir. %2 = procedure a appeler pour
; chaque unite.
; ============================================================
%macro def_tx_hex_nibble 2
%1:
        ; Entree: AL (4 bits utiles) = valeur 0-15 a afficher
        push    bx
        and     al, 0Fh
        mov     bl, al
        xor     bh, bh
        mov     al, [hex_table + bx]
        call    %2
        pop     bx
        ret
%endmacro

%macro def_tx_hex_byte 2
%1:
        ; Entree: AL = octet a afficher (2 caracteres hex)
        push    bx
        mov     bl, al          ; BL = copie de l'octet
        mov     al, bl
        shr     al, 1           ; 4x SHR reg,1: seul decalage disponible
        shr     al, 1           ; sur un vrai 8086/8088 (immediat != 1
        shr     al, 1           ; interdit avant le 80186)
        shr     al, 1           ; AL = nibble de poids fort
        call    %2
        mov     al, bl          ; AL = octet original (nibble de poids
        call    %2              ; faible - le AND est fait dans nibble)
        pop     bx
        ret
%endmacro

%macro def_tx_hex_word 2
%1:
        ; Entree: AX = mot a afficher (4 caracteres hex, octet fort en 1er)
        push    bx
        mov     bx, ax
        mov     al, bh
        call    %2
        mov     al, bl
        call    %2
        pop     bx
        ret
%endmacro

; ============================================================
; def_busy_delay
; Generateur de boucle d'attente active (dec bx/jnz) - motif
; identique utilise par lcd_short_delai/lcd_delay/lcd_delay_long
; (lib/lcd.asm), i2c_delay (lib/lcd_i2c.asm) et uart_bit_delay
; (lib/uart.asm), avec seul le nombre d'iterations qui change.
; %1 = nom de la procedure a definir, %2 = nombre d'iterations (BX)
; ============================================================
%macro def_busy_delay 2
%1:
        push    bx
        mov     bx, %2
%%d:
        dec     bx
        jnz     %%d
        pop     bx
        ret
%endmacro

%endif ; COMMON_ASM
