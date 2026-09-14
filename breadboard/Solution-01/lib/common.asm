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

%endif ; COMMON_ASM
