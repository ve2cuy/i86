BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; Test de cablage "bit par bit" sur le port 10h, pour eliminer
; les causes electriques avant de reprendre le debogage du LCD.
;
; Allume les LED une a la suite de l'autre (bit0, puis bit1,
; puis bit2, ...) avec un delai de 1000 ms entre chaque, SANS
; eteindre les LED deja allumees. Une fois les 8 LED allumees,
; le cycle recommence (toutes les LED s'eteignent, puis on
; repart de bit0). Ce redemarrage n'etait pas explicitement
; demande - si tu preferais un arret (halt) apres le bit7 au
; lieu d'une boucle infinie, dis-le moi.
; ------------------------------------------------------------
STACK_SEG       equ     1000h

start:
        cli
        mov     ax, STACK_SEG
        mov     ss, ax          ; SS = 1000h -> pile en fin de RAM (128K)
        mov     sp, 0000h
        sti

.restart:
        xor     al, al
        out     10h, al         ; eteint toutes les LED (etat de depart du cycle)

        mov     bl, 00000001b   ; premiere LED a allumer: bit0

.next_led:
        or      al, bl          ; ajoute la LED courante SANS effacer les precedentes
        out     10h, al

        mov     cx, 1000        ; delai de 1000 ms = 1 seconde
        call    delay_ms

        shl     bl, 1           ; LED suivante (SHL reg,1 - seul decalage disponible
                                 ; sur un vrai 8086/8088, pas de SHL reg,imm>1)
        jnz     .next_led       ; continue tant qu'il reste un bit a allumer
                                 ; (bl devient 0 juste apres avoir traite le bit7)

        jmp     .restart        ; les 8 LED etaient allumees: on recommence le cycle

; ============================================================
; delay_ms
; Delai en millisecondes.
; Entree: CX = nombre de millisecondes a attendre.
;
; Boucle externe: une iteration par ms (via l'instruction LOOP,
; qui decremente CX directement - c'est le registre "parametre").
; Boucle interne: calibree pour ~1 ms, en supposant une horloge
; a 4,77 MHz et les temps d'execution 8086/8088 approximatifs
; suivants: DEC reg16 = 2 cycles, JNZ pris = 16 cycles (soit
; ~18 cycles/iteration). 4 770 000 Hz x 0,001 s / 18 ~= 265.
;
; ATTENTION: comme pour "delai"/"delai_blink" ailleurs dans ce
; projet, c'est une estimation - la frequence reelle de ton
; montage et les delais d'acces bus peuvent differer. Si le
; rythme observe n'est pas ~1 seconde par LED, ajuste INNER_MS
; en consequence (l'augmenter si c'est trop rapide, le diminuer
; si c'est trop lent).
; ============================================================
INNER_MS        equ     265     ; ~1 ms a 4,77 MHz (approximatif)

delay_ms:
        push    bx
        push    cx              ; preserve la valeur d'entree (bonne pratique,
                                 ; meme si le programme principal recharge CX
                                 ; avant chaque appel)
.outer:
        mov     bx, INNER_MS
.inner:
        dec     bx
        jnz     .inner
        loop    .outer          ; CX-- ; si CX != 0, recommence .outer

        pop     cx
        pop     bx
        ret

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
