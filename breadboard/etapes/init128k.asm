BITS    16
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; Version simplifiee (sans verification, sans diagnostic) pour
; isoler si le simple fait de remplir puis relire toute la RAM
; (128K - 1K) suffit a reproduire le comportement erratique, ou
; si c'est specifique a l'ecriture/relecture immediate au meme
; octet utilisee par test_segment.
;
; Meme structure que init4096.asm, etendue a 128K - 1K (130048
; octets = 127 x 1024), au lieu des 4096 premiers octets.
;
; RAM statique de 128K: physique 00000h-1FFFFh. Comme dans les
; versions precedentes, le dernier kilo-octet du segment 1000h
; (offsets FC00h-FFFFh, physique 1FC00h-1FFFFh) est reserve a la
; pile et n'est PAS touche par init_ram/read_ram.
; ------------------------------------------------------------
STACK_SEG       equ     1000h

start:
        cli                     ; pas d'interruption pendant l'init de SS:SP
        xor     ax, ax
        mov     ds, ax          ; DS = 0000h -> debut de la RAM

        mov     ax, STACK_SEG
        mov     ss, ax          ; SS = 1000h -> pile en fin de RAM
        mov     sp, 0000h       ; SP = 0000h -> sommet de la pile
        sti                     ; NOTE: absent de init4096.asm - ajoute ici
                                 ; car init_ram/read_ram utilisent push/pop,
                                 ; et on touche maintenant toute la RAM (y
                                 ; compris la zone ou vit la pile elle-meme)

        call    init_ram        ; remplit 130048 octets de RAM (128K - 1K)
        call    read_ram        ; relit ces octets et les envoie sur OUT 10h

        jmp     start           ; boucle infinie (recommence)

; ============================================================
; init_ram
; Initialise 130048 octets de RAM (128K - 1K), en 2 segments de
; 64K (0000h et 1000h, ce dernier tronque de 1024 octets reserves
; a la pile), avec un motif de test: octet[i] = i mod 256
; (00h,01h,...,FFh,00h,...). Ce motif facilite la verification a
; la relecture.
; ============================================================
init_ram:
        push    ax
        push    bx
        push    cx
        push    di
        push    es

        ; --- Segment 0000h: physique 00000h-0FFFFh, rempli en entier (64K) ---
        xor     ax, ax
        mov     es, ax          ; ES = 0000h -> segment de la RAM basse
        xor     di, di          ; DI = 0000h -> offset de depart (00000h)
        mov     cx, 0           ; CX=0 -> 65536 iterations (astuce classique avec LOOP)
        xor     al, al          ; AL = valeur de depart du motif

.fill1:
        mov     [es:di], al     ; ecrit l'octet courant en RAM
        inc     al              ; motif incremental (revient a 00h apres FFh)
        inc     di
        loop    .fill1

        ; --- Segment 1000h: physique 10000h-1FFFFh, moins le dernier ---
        ; --- kilo-octet reserve a la pile -> 64512 octets remplis    ---
        mov     bx, STACK_SEG   ; BX (pas AX) pour ne pas perdre le motif dans AL
        mov     es, bx
        xor     di, di
        mov     cx, 64512       ; 65536 - 1024 (zone reservee a la pile)

.fill2:
        mov     [es:di], al
        inc     al
        inc     di
        loop    .fill2

        pop     es
        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; read_ram
; Relit les 130048 octets de RAM (128K - 1K, memes 2 segments
; que init_ram) et envoie chaque octet sur OUT 10h, avec un
; delai de presentation entre chaque valeur.
; ============================================================
read_ram:
        push    ax
        push    bx
        push    cx
        push    si
        push    ds

        ; --- Segment 0000h: physique 00000h-0FFFFh, relu en entier (64K) ---
        xor     ax, ax
        mov     ds, ax          ; DS = 0000h -> segment de la RAM basse
        xor     si, si          ; SI = 0000h -> offset de depart (00000h)
        mov     cx, 0           ; CX=0 -> 65536 iterations

.loop1:
        mov     al, [ds:si]     ; lit l'octet en RAM
        out     10h, al         ; l'envoie sur le port 10h

        push    cx
        call    delai
        pop     cx

        inc     si
        loop    .loop1

        ; --- Segment 1000h: physique 10000h-1FFFFh, moins le dernier ---
        ; --- kilo-octet reserve a la pile -> 64512 octets relus       ---
        mov     bx, STACK_SEG
        mov     ds, bx
        xor     si, si
        mov     cx, 64512

.loop2:
        mov     al, [ds:si]
        out     10h, al

        push    cx
        call    delai
        pop     cx

        inc     si
        loop    .loop2

        pop     ds
        pop     si
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; delai
; Delai de presentation entre deux octets envoyes sur OUT 10h.
; Ajuster la valeur chargee dans BX pour changer la duree.
; ============================================================
delai:
        push    bx
        mov     bx, 0FFFFh      ; a ajuster selon le delai souhaite
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- À ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
