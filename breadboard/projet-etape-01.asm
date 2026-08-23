; ==============================================
; Boot ROM 8088 - 256K, mappee en C0000h-FFFFFh
; Syntaxe NASM
; nasm -f bin flashLed-v2.asm -o rom_final.bin
; ==============================================

; -----------------------------------------------------------------------------------------------
; Version initiale du programme flashLed.asm:
; Circuit:
;
;       - Tous les signaux d'adresse [A0..A19] et de data [AD0..AD7] du 8088 sont
;         connectés sur des 74LS373/74LS245. 
;
;       - Pour l'adressage RAM/ROM, un circuit tout simple est utilise:
;         Si A19=0 et A18=0, alors RAM est selectionnee, sinon ROM est selectionnee.
;         C0000h = 11000000000000000000.
;
;       - ROM WINBOND W29C020C 256K (C0000h-FFFFFh) sur [A0..A17] et [AD0..AD7] du 8088.
;         WE_ (31) sur VCC, 
;         OE_ (24) sur RD_ (20) du 8088, 
;         CE_ (22) sur NAND de A18 et A19. 
;
;       - RAM HM628128 128k (0000h-1FFFFh) sur [A0..A16] et [AD0..AD7] du 8088.
;         CS1_ (22)
;         CS2  (30)
;         OE_  (24)
;         WE_  (29)
;         74LS32 : L + L -> L
;         OE# (pin 32)	RD# du CPU (partagé avec la ROM)
;         
; -------------------------------------------------------------------------------------------------
;       - Les LEDS via un 74LS373 (latch) sur le port 10h.  
;         Note: Peu importe le port utilisé, présentement, la broche 11 'C' du latch 
;               est connectée sur la broche 28 'IO/M_' du 8088 
;               et la broche 1 'OC' du latch est au ground.
;               Donc, un simple OUT x,y sera suffisant pour mettre à jour les LEDS.
;

;
; ------------------------------------------------------------------------------------------------

BITS    16
ORG     0000h                   ; = physique C0000h (debut de la ROM)

start:
        mov     al, 10101010b   ; AL = 10101010b
        out     10h, al         ; envoie AL sur le port 10h

        mov     bx, 0000h       ; compteur de delai
delai1:
        dec     bx
        jnz     delai1          ; boucle jusqu'a BX = 0

        mov     al, 01010101b   ; AL = 01010101b
        out     10h, al

        mov     bx, 0000h
delai2:
        dec     bx
        jnz     delai2

        jmp     start           ; boucle infinie

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- À ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
