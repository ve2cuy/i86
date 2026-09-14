BITS    16
ORG     0000h                   ; = physique C0000h (debut de la ROM)

start:
        call    init_ram        ; initialise les 4096 premiers octets de RAM
        call    read_ram        ; relit ces octets et les envoie sur OUT 10h

        jmp     start           ; boucle infinie (recommence le test)

; ============================================================
; init_ram
; Initialise les 4096 premiers octets de la RAM (00000h-00FFFh)
; avec un motif de test: octet[i] = i mod 256 (00h,01h,...,FFh,
; 00h,01h,...). Ce motif facilite la verification a la relecture.
; ============================================================
init_ram:
        push    ax
        push    cx
        push    di
        push    es

        xor     ax, ax
        mov     es, ax          ; ES = 0000h -> segment de la RAM basse
        xor     di, di          ; DI = 0000h -> offset de depart (00000h)
        mov     cx, 4096        ; nombre d'octets a initialiser
        xor     al, al          ; AL = valeur de depart du motif

.fill:
        mov     [es:di], al     ; ecrit l'octet courant en RAM
        inc     al              ; motif incremental (revient a 00h apres FFh)
        inc     di
        loop    .fill

        pop     es
        pop     di
        pop     cx
        pop     ax
        ret

; ============================================================
; read_ram
; Relit les 4096 premiers octets de la RAM (00000h-00FFFh) et
; envoie chaque octet sur OUT 10h, avec un delai de presentation
; entre chaque valeur (voir la procedure "delai").
; ============================================================
read_ram:
        push    ax
        push    cx
        push    si
        push    ds

        xor     ax, ax
        mov     ds, ax          ; DS = 0000h -> segment de la RAM basse
        xor     si, si          ; SI = 0000h -> offset de depart (00000h)
        mov     cx, 4096        ; nombre d'octets a relire

.loop:
        mov     al, [ds:si]     ; lit l'octet en RAM
        out     10h, al         ; l'envoie sur le port 10h

        push    cx
        call    delai
        pop     cx

        inc     si
        loop    .loop

        pop     ds
        pop     si
        pop     cx
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
