BITS    16
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; Montage: RAM statique de 128K, adressee de 00000h a 1FFFFh.
; La pile est placee en fin de cette RAM:
;   SS = 1000h -> base physique 10000h
;   SP = 0000h -> premier push ecrit en 1FFFEh-1FFFFh
;                 (les 2 derniers octets de la RAM de 128K)
; ------------------------------------------------------------
STACK_SEG       equ     1000h

start:
        cli                     ; pas d'interruption pendant l'init de SS:SP
        xor     ax, ax
        mov     ds, ax          ; DS = 0000h -> debut de la RAM (128K)

        mov     ax, STACK_SEG
        mov     ss, ax          ; SS = 1000h -> pile en fin de RAM
        mov     sp, 0000h       ; SP = 0000h -> sommet de la pile, remis a zero
                                 ; a CHAQUE cycle (voir plus bas pourquoi c'est
                                 ; important)
        sti

        call    test_ram        ; teste toute la RAM (128K) et signale le resultat
        jmp     start           ; test_ram est revenu (ret) -> nouveau cycle complet

; ============================================================
; test_ram
; Teste la totalite de la RAM statique de 128K (00000h-1FFFFh),
; par blocs de 64K (2 segments: 0000h et 1000h).
;
; IMPORTANT - zone reservee a la pile:
;   La pile (SS=1000h, SP=0000h) vit dans la RAM qu'on teste. On
;   reserve donc le dernier kilo-octet du segment 1000h (offsets
;   FC00h-FFFFh, physique 1FC00h-1FFFFh) et on NE LE TESTE PAS,
;   pour ne jamais ecraser la pile active pendant le test (meme
;   temporairement). Ca laisse une marge tres large: la pile de
;   ce programme n'utilise jamais plus qu'une poignee d'octets.
;   Resultat: 130048 octets testes sur 131072 (127 x 1024), le
;   dernier 1024 octets etant la marge de securite pour la pile.
;
; IMPORTANT - call/ret equilibres (pas de saut "spaghetti"):
;   Cette routine retourne normalement (ret) vers "start", qui
;   fait "jmp start" pour relancer un nouveau cycle. Chaque
;   "call test_ram" est donc suivi exactement d'un "ret" - la
;   pile ne derive jamais, peu importe le nombre de cycles.
;   Comme "start" remet SP a 0000h avant chaque "call test_ram",
;   la remise a zero est en fait redondante ici (le call/ret
;   equilibre suffirait a lui seul), mais elle est gardee par
;   prudence: elle ne coute rien et protege contre toute future
;   modification qui deséquilibrerait accidentellement un appel.
;
; Chaque bloc de 1024 octets teste, on incremente et affiche la
; progression sur OUT 10h (voir test_segment). A la fin, on
; clignote les LED: 3 fois si toute la RAM testee est valide,
; 5 fois si au moins un octet defectueux a ete detecte.
; ============================================================
test_ram:
        cli                     ; pas d'interruption pendant tout le test
        xor     bh, bh          ; BH = drapeau d'erreur global (0 = RAM valide)
        xor     dx, dx          ; DL = compteur de progression (paliers de 1024 octets)

        ; --- Segment 0000h: physique 00000h-0FFFFh, teste en entier (64K) ---
        xor     ax, ax
        mov     es, ax
        xor     di, di
        mov     cx, 0           ; CX=0 -> 65536 iterations (astuce classique avec LOOP)
        call    test_segment

        ; --- Segment 1000h: physique 10000h-1FFFFh, moins le dernier ---
        ; --- kilo-octet reserve a la pile -> 64512 octets testes     ---
        mov     ax, STACK_SEG
        mov     es, ax
        xor     di, di
        mov     cx, 64512       ; 65536 - 1024 (zone reservee, voir plus haut)
        call    test_segment

        ; --- Resultat final ---
        cmp     bh, 0
        je      .ram_ok

        mov     cx, 5           ; RAM defectueuse -> 5 clignotements
        call    blink
        ret                     ; retourne a "start" (qui relance un nouveau cycle)

.ram_ok:
        mov     cx, 3           ; RAM valide -> 3 clignotements
        call    blink
        ret                     ; retourne a "start" (qui relance un nouveau cycle)

; ============================================================
; test_segment
; Teste CX octets a partir de ES:DI (destructif mais restaure
; chaque octet aussitot apres verification - "non destructif" au
; final). Deux motifs de test par octet: 10101010b puis 01010101b
; (complementaires, pour detecter les bits colles a 0 ou a 1).
;
; Entree:  ES:DI = adresse de depart, CX = nombre d'octets
; Modifie: BH (leve a 1 si un octet est defectueux), DL (avance
;          d'un cran a chaque palier de 1024 octets testes)
; ============================================================
test_segment:
.byte_loop:
        mov     bl, [es:di]     ; sauvegarde l'octet original

        mov     al, 10101010b   ; motif de test #1
        mov     [es:di], al
        mov     al, [es:di]     ; relecture (verifie vraiment la RAM)
        cmp     al, 10101010b
        jne     .fault

        mov     al, 01010101b   ; motif de test #2 (complement du #1)
        mov     [es:di], al
        mov     al, [es:di]
        cmp     al, 01010101b
        jne     .fault

        jmp     .restore
.fault:
        mov     bh, 1           ; octet defectueux: leve le drapeau global
.restore:
        mov     [es:di], bl     ; restaure la valeur d'origine de l'octet

        inc     di
        test    di, 03FFh       ; DI multiple de 1024 ? (1024 octets testes)
        jnz     .no_checkpoint

        inc     dl              ; palier suivant
        mov     al, dl
        out     10h, al         ; affiche la progression
        call    delai

.no_checkpoint:
        loop    .byte_loop
        ret

; ============================================================
; blink
; Fait clignoter toutes les LED (OUT 10h) CX fois: allumees puis
; eteintes, avec un delai entre chaque etat.
; Entree: CX = nombre de clignotements
; ============================================================
blink:
.blink_loop:
        mov     al, 0FFh        ; toutes les LED allumees
        out     10h, al
        call    delai
        mov     al, 000h        ; toutes les LED eteintes
        out     10h, al
        call    delai
        loop    .blink_loop
        ret

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
        mov     cx, 4096        ; nombre d'octets a initialiser, utilisé pour la boucle (loop)
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
        mov     bx, 000FFh      ; a ajuster selon le delai souhaite
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
