; ==============================================
; Boot ROM 8088 - 256K, mappee en C0000h-FFFFFh
; Syntaxe NASM
; nasm -f bin flashLed-v2.asm -o rom_final.bin
; ==============================================

BITS    16
ORG     0000h                  ; = physique C0000h (debut de la ROM)

start:
        mov     al, 10101010b        ; AL = 10101010b
        out     10h, al         ; envoie AL sur le port 10h

        mov     bx, 0000h       ; compteur de delai
delai1:
        dec     bx
        jnz     delai1          ; boucle jusqu'a BX = 0

        mov     al, 01010101b         ; AL = 01010101b
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
