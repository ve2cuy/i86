BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; ram_test_uart_3.asm
; nasm -f bin ram_test_uart_3.asm -o Z:\Partage\Alain\ram_test_uart_3.bin
; ------------------------------------------------------------
; Reprend le test de la RAM statique 128K (voir diag_A.asm et
; diag_B.asm) mais remplace entierement le compte-rendu par LED
; (OUT 10h + clignotements) par un compte-rendu texte envoye sur
; l'UART bit-bange (9600 bauds, 8N1 - voir uart_hello_2.asm):
;   - chaque bloc de 1 Ko teste est affiche avec son adresse
;     SEGMENT:OFFSET en hexadecimal, suivi d'un "OK" (vert) ou
;     "DEFAUT" (rouge);
;   - chaque octet defectueux declenche une ligne de detail en
;     rouge avec son adresse exacte et les valeurs attendue/lue;
;   - un bilan final en vert (RAM OK) ou rouge (RAM DEFECTUEUSE)
;     cloture le test de la RAM.
;
; NOUVEAU dans cette version: apres le test de la RAM, dump des
; 16 premiers Ko de la ROM au format classique adresse/hexa/
; ascii, ex: "C000:0000 FF FF FF ... FF : ................".
; L'adresse affichee est maintenant l'adresse REELLE (segment
; materiel CS, = C000h sur ce montage) et non plus une adresse
; logique relative a 0000h. Voir rom_dump plus bas.
;
; Cablage UART: bit0 du port 10h -> RX d'un adaptateur USB-serie
; (FTDI/CP2102...), masse commune. Terminal cote PC: 9600 8N1,
; VT100/ANSI actif (PuTTY, TeraTerm, minicom... tous conviennent).
; ------------------------------------------------------------
STACK_SEG       equ     1000h

UART_TX         equ     00000001b       ; bit0
UART_IDLE       equ     00000001b       ; ligne au repos (MARK) = 1
SECONDE         equ     1000            ; 1 seconde = 1000 ms

;*****************
; CONST. PIO 1   *
;*****************
PORTA       EQU    10000000B   ;8255 ACTIVE PAR A7
PORTB       EQU    10000001B
PORTC       EQU    10000010B
PIO         EQU    10000011B
MASQUE_PIO  EQU    10000000B   ;PORT A,B ET C EN SORTIES
; MASQUE_PIO2 EQU    10001001B   ;PORT A ET B EN SORTIES, C EN ENTREE

%macro cls 0
        mov     si, CLS         ; efface l'ecran du terminal (ANSI)
        call    uart_tx_string
%endmacro

; UART_BIT_COUNT: valeur validee sur ce montage dans uart_hello_2.asm
; (mesuree a l'analyseur logique: 105us, cible 104.17us -> <1% d'ecart,
; largement dans la tolerance habituelle de +/-2-3%). Ne pas modifier
; sans re-mesurer.
UART_BIT_COUNT  equ     17

start:
        cli                     ; pas d'interruption pendant l'init de SS:SP
        mov     ax, STACK_SEG
        mov     ss, ax          ; SS = 1000h -> pile en fin de RAM (128K)
        mov     sp, 0000h       ; SP = 0000h -> sommet de la pile, remis a zero
                                 ; a CHAQUE cycle
        sti

        mov     ax, cs
        mov     ds, ax          ; DS = CS en PERMANENCE: tous les messages et
                                 ; la table hexadecimale vivent dans la ROM.
                                 ; La RAM sous test est accedee EXCLUSIVEMENT
                                 ; via ES (jamais DS), pour ne jamais avoir a
                                 ; changer DS pendant le test.

        mov     al, UART_IDLE
        out     10h, al         ; ligne UART au repos des le debut

.ici:
        cls                     ; efface l'ecran du terminal (ANSI)
        mov     si, txt_auteur
        call    uart_tx_string
        mov     cx, SECONDE     ; pause de 1 seconde avant de débuter le test (permet de voir le message de depart)
        call    delay_ms

.temp:        
        mov     si, txt_8255_init
        call    uart_tx_string        
        call    init_8255
        call    effet1
;        jmp     .temp

        call    test_ram        ; teste toute la RAM (128K) et rapporte via UART
        call    rom_dump        ; dump des 16 premiers Ko de la ROM - voir plus bas

        mov     cx, 2 * SECONDE ; pause de 2 secondes avant de relancer un cycle
        call    delay_ms
        jmp     .ici            ; reboucle indefiniment

; ============================================================
; test_ram
; Teste la totalite de la RAM statique de 128K (00000h-1FFFFh),
; par blocs de 64K (2 segments: 0000h et 1000h), moins le
; dernier Ko du segment 1000h reserve a la pile active (voir
; diag_A.asm/diag_B.asm pour la justification complete de cette
; reserve et de l'equilibre call/ret).
; Resultat: 130048 octets testes sur 131072 (127 blocs de 1 Ko).
; ============================================================
test_ram:
        cli                     ; pas d'interruption pendant tout le test
                                 ; (encore plus important ici: protege aussi
                                 ; le timing bit a bit de l'UART)
        xor     bh, bh          ; BH = drapeau d'erreur GLOBAL (0 = RAM valide)
        xor     bp, bp          ; BP = drapeau d'erreur du BLOC courant

        call    msg_banniere

        ; --- Segment 0000h: physique 00000h-0FFFFh, teste en entier (64K) ---
        xor     ax, ax
        mov     es, ax
        xor     di, di
        mov     cx, 0           ; CX=0 -> 65536 iterations (astuce classique)
        call    test_segment

        ; --- Segment 1000h: physique 10000h-1FFFFh, moins le dernier ---
        ; --- kilo-octet reserve a la pile -> 64512 octets testes     ---
        mov     ax, STACK_SEG
        mov     es, ax
        xor     di, di
        mov     cx, 64512       ; 65536 - 1024 (zone reservee a la pile)
        call    test_segment

        ; --- Bilan final ---
        cmp     bh, 0
        je      .ram_ok

        call    msg_ram_defectueuse
        ret                     ; retourne a .ici (qui enchaine avec rom_dump)

.ram_ok:
        call    msg_ram_ok
        ret

; ============================================================
; test_segment
; Teste CX octets a partir de ES:DI (destructif mais restaure
; chaque octet aussitot apres verification). Deux motifs de test
; par octet: 10101010b puis 01010101b (complementaires, pour
; detecter les bits colles a 0 ou a 1) - inchange par rapport a
; diag_A.asm/diag_B.asm.
;
; Entree:  ES:DI = adresse de depart, CX = nombre d'octets
; Modifie: BH (drapeau global), BP (drapeau du bloc courant, se
;          reinitialise a chaque bloc de 1024 octets rapporte)
; ============================================================
test_segment:
.byte_loop:
        mov     bl, [es:di]     ; sauvegarde l'octet original

        mov     al, 10101010b   ; motif de test #1
        mov     [es:di], al
        mov     al, [es:di]     ; relecture (verifie vraiment la RAM)
        mov     dl, al          ; DL = valeur relue (pour le rapport eventuel)
        cmp     al, 10101010b
        jne     .fault_1

        mov     al, 01010101b   ; motif de test #2 (complement du #1)
        mov     [es:di], al
        mov     al, [es:di]
        mov     dl, al
        cmp     al, 01010101b
        jne     .fault_2

        jmp     .restore

.fault_1:
        mov     dh, 10101010b   ; DH = valeur attendue
        jmp     .fault_common
.fault_2:
        mov     dh, 01010101b
.fault_common:
        mov     bh, 1           ; leve le drapeau global (RAM defectueuse)
        mov     bp, 1           ; leve le drapeau du bloc courant
        call    msg_defaut_detail      ; rapport immediat: adresse ES:DI,
                                        ; attendu=DH, lu=DL (en rouge)
.restore:
        mov     [es:di], bl     ; restaure la valeur d'origine de l'octet

        inc     di
        test    di, 03FFh       ; DI multiple de 1024 ? (1 bloc complet teste)
        jnz     .no_checkpoint

        call    msg_bloc_progression    ; affiche ES:debut-ES:fin + OK/DEFAUT,
                                         ; et reinitialise BP a 0

.no_checkpoint:
        loop    .byte_loop
        ret

; ============================================================
; rom_dump
; Affiche les ROM_DUMP_SIZE premiers octets de la ROM au format:
;   SEG:OFFSET  b0 b1 ... b15  : c0 c1 ... c15
; ou b0..b15 sont les 16 octets en hexadecimal (2 chiffres,
; majuscules) et c0..c15 le caractere ASCII correspondant si
; imprimable (20h-7Eh), sinon '.'.
;
; Adressage affiche: REEL (segment materiel ES = CS, = C000h sur
; ce montage) - contrairement a une version precedente qui
; affichait une adresse "logique" relative a 0000h, l'adresse
; imprimee ici correspond exactement a ce qu'on verrait avec un
; debogueur materiel (SEG:OFFSET reel).
;
; Limite a ROM_DUMP_SIZE = 4000h (16 Ko, 1024 lignes) pour rester
; rapide: a 9600 bauds (~960 car/s) et ~78 caracteres/ligne, ca
; prend environ 83 secondes (contre ~22 minutes pour les 256 Ko
; complets). 16 Ko reste largement dans le premier segment (donc
; pas de risque de depassement de segment: DI va simplement de
; 0000h a 3FF0h, jamais jusqu'a FFFFh).
; ============================================================
ROM_DUMP_SIZE   equ     4000h           ; 16 Ko a dumper

rom_dump:
        push    ax
        push    cx
        push    dx
        push    si
        push    di
        push    es

        call    msg_dump_banniere

        mov     ax, cs
        mov     es, ax          ; ES = segment materiel REEL (CS), affiche tel quel

        xor     di, di
.line_loop:
        ; --- adresse reelle ES:DI ---
        mov     ax, es
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, di
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte

        ; --- 16 octets en hexadecimal ---
        push    di
        mov     cx, 16
.hex_loop:
        mov     al, [es:di]
        call    uart_tx_hex_byte
        mov     al, ' '
        call    uart_tx_byte
        inc     di
        loop    .hex_loop
        pop     di

        mov     al, ':'
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte

        ; --- 16 caracteres ASCII (ou '.' si non imprimable) ---
        mov     cx, 16
.ascii_loop:
        mov     al, [es:di]
        cmp     al, 20h         ; < espace -> non imprimable
        jb      .not_printable
        cmp     al, 7Eh         ; > '~' -> non imprimable
        ja      .not_printable
        jmp     .print_char
.not_printable:
        mov     al, '.'
.print_char:
        call    uart_tx_byte
        inc     di
        loop    .ascii_loop

        mov     si, txt_crlf
        call    uart_tx_string

        cmp     di, ROM_DUMP_SIZE       ; les 16 Ko demandes sont-ils affiches ?
        jb      .line_loop

        call    msg_dump_fin

        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; uart_tx_string / uart_tx_byte / uart_bit_delay / delay_ms
; Identiques a uart_hello_2.asm (voir ce fichier pour le detail
; et l'historique de calibration de UART_BIT_COUNT).
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

uart_tx_byte:
        push    ax
        push    cx
        push    dx
        mov     dl, al          ; DL = copie de l'octet a transmettre

        mov     al, 0           ; --- bit de start ---
        out     10h, al
        call    uart_bit_delay

        mov     cl, 8           ; --- 8 bits de donnees, LSB en premier ---
.bitloop:
        mov     al, dl
        and     al, 00000001b
        cmp     al, 0
        je      .bit_zero
        mov     al, UART_TX
        jmp     .send_bit
.bit_zero:
        mov     al, 0
.send_bit:
        out     10h, al
        call    uart_bit_delay

        shr     dl, 1
        dec     cl
        jnz     .bitloop

        mov     al, UART_IDLE   ; --- bit de stop ---
        out     10h, al
        call    uart_bit_delay

        pop     dx
        pop     cx
        pop     ax
        ret

uart_bit_delay:
        push    bx
        mov     bx, UART_BIT_COUNT
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

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

; ============================================================
; uart_tx_hex_nibble / uart_tx_hex_byte / uart_tx_hex_word
; Affichent une valeur en hexadecimal (majuscules) via l'UART.
; Detruisent AX et BX (jamais CX/DX/SI/DI/ES/BP: sans danger a
; appeler depuis test_segment ou rom_dump au milieu d'une boucle).
; ============================================================
uart_tx_hex_nibble:
        ; Entree: AL (4 bits utiles) = valeur 0-15 a afficher
        push    bx
        and     al, 0Fh
        mov     bl, al
        xor     bh, bh
        mov     al, [hex_table + bx]
        call    uart_tx_byte
        pop     bx
        ret

uart_tx_hex_byte:
        ; Entree: AL = octet a afficher (2 caracteres hex)
        push    bx
        mov     bl, al          ; BL = copie de l'octet
        mov     al, bl
        shr     al, 1           ; 4x SHR reg,1: seul decalage disponible
        shr     al, 1           ; sur un vrai 8086/8088 (immediat != 1
        shr     al, 1           ; interdit avant le 80186)
        shr     al, 1           ; AL = nibble de poids fort
        call    uart_tx_hex_nibble
        mov     al, bl          ; AL = octet original (nibble de poids
        call    uart_tx_hex_nibble     ; faible - le AND est fait dans nibble)
        pop     bx
        ret

uart_tx_hex_word:
        ; Entree: AX = mot a afficher (4 caracteres hex, octet fort en 1er)
        push    bx
        mov     bx, ax
        mov     al, bh
        call    uart_tx_hex_byte
        mov     al, bl
        call    uart_tx_hex_byte
        pop     bx
        ret

; ============================================================
; msg_banniere
; Annonce le debut du test avec le plan des blocs a tester.
; ============================================================
msg_banniere:
        mov     si, txt_banniere1
        call    uart_tx_string
        mov     si, txt_banniere2
        call    uart_tx_string
        ret

; ============================================================
; msg_bloc_progression
; Affiche le bloc de 1024 octets qui vient d'etre teste:
; "SEG:debut-SEG:fin <vert>OK<blanc>"  (ou <rouge>DEFAUT)
; Entree: ES = segment courant, DI = offset JUSTE APRES le bloc
;         (multiple de 400h), BP = drapeau du bloc (0=ok, sinon defaut)
; Reinitialise BP a 0 avant de retourner.
; ============================================================
msg_bloc_progression:
        mov     si, ANSI_BLANC
        call    uart_tx_string

        mov     ax, es
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, di
        sub     ax, 0400h       ; ax = debut du bloc (di - 1024)
        call    uart_tx_hex_word

        mov     al, '-'
        call    uart_tx_byte

        mov     ax, es
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, di
        dec     ax              ; ax = fin du bloc (di - 1)
        call    uart_tx_hex_word

        mov     al, ' '
        call    uart_tx_byte

        mov     si, ANSI_BLANC
        call    uart_tx_string

        cmp     bp, 0
        je      .ok
        mov     si, ANSI_ROUGE
        call    uart_tx_string
        mov     si, txt_defaut_court
        call    uart_tx_string
        jmp     .fin
.ok:
        mov     si, ANSI_VERT
        call    uart_tx_string
        mov     si, txt_ok_court
        call    uart_tx_string
.fin:
        mov     bp, 0           ; reinitialise le drapeau pour le prochain bloc
        ret

; ============================================================
; msg_defaut_detail
; Rapporte immediatement un octet defectueux (en rouge), avec
; son adresse exacte et les valeurs attendue/lue en hexadecimal.
; Entree: ES:DI = adresse de l'octet, DH = valeur attendue,
;         DL = valeur relue.
; ============================================================
msg_defaut_detail:
        ; DX (attendu/lu) survit tel quel a tous les appels ci-dessous:
        ; aucune des routines uart_tx_*/uart_bit_delay/delay_ms ne
        ; touche DX (voir leurs en-tetes) - un seul push/pop suffit.
        push    ax
        push    dx

        mov     si, ANSI_ROUGE
        call    uart_tx_string
        mov     si, txt_defaut_detail
        call    uart_tx_string

        mov     ax, es
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, di
        call    uart_tx_hex_word

        mov     si, txt_attendu
        call    uart_tx_string
        mov     al, dh
        call    uart_tx_hex_byte

        mov     si, txt_lu
        call    uart_tx_string
        mov     al, dl
        call    uart_tx_hex_byte

        mov     si, ANSI_BLANC
        call    uart_tx_string
        mov     si, txt_crlf
        call    uart_tx_string

        pop     dx
        pop     ax
        ret

; ============================================================
; msg_ram_ok / msg_ram_defectueuse
; Bilan final du test RAM (une ligne, en couleur).
; ============================================================
msg_ram_ok:
        mov     si, txt_ram_ok
        call    uart_tx_string
        ret

msg_ram_defectueuse:
        mov     si, txt_ram_defaut
        call    uart_tx_string
        ret

; ============================================================
; msg_dump_banniere / msg_dump_fin
; Annonce/cloture du dump ROM (une ligne, en couleur).
; ============================================================
msg_dump_banniere:
        mov     si, txt_dump_banniere
        call    uart_tx_string
        ret

msg_dump_fin:
        mov     si, txt_dump_fin
        call    uart_tx_string
        ret


; -------------------------------------------------------------------------------------------------
; Section suivante: routines d'initialisation et de controle des 8255 (PIO)
; -------------------------------------------------------------------------------------------------

;****************************************
;* init 8255's			                *
;****************************************
init_8255:

        ;*********************
        ; INIT LA 8255 NO. 1 *
        ;*********************
        ;-----------------------------------------
        ; LES 8255 SERVENT AU CONTROLE DU CLAVIER
        ; ET DE L'ECRAN.
        ;----------------------------------------
        MOV    AL,MASQUE_PIO  ; PORT A,B ET C EN SORTIE
        OUT    PIO,AL         ; CMD LA 8255
        MOV    AL,0
        OUT    PORTA,AL
        OUT    PORTB,AL
        OUT    PORTC,AL

        ;********************
        ; INIT LA 8255 NO. 2 *
        ;********************
        ;MOV    AL,MASQUE_PIO  
        ;OUT    PIO2,AL        ; CMD LA 8255
        ;MOV    AL,0
        ;OUT    PORT2A,AL
        ;OUT    PORT2B,AL
        ;OUT    PORT2C,AL
 
        ;********************
        ; INIT LA 8255 NO. 3 *
        ;********************
        ;MOV    AL,MASQUE_PIO  
        ;OUT    PIO3,AL        ; CMD LA 8255
        ;MOV    AL,0
        ;OUT    PORT3A,AL
        ;OUT    PORT3B,AL
        ;OUT    PORT3C,AL

	ret
; ***************************************


;****************************************
;* clear_5255A..                        *
;****************************************

clear_8255A:
	push 	ax
	mov	al, 0
	call	proc1
	pop	ax
	ret
			   
;****************************************
;* proc1     ...                        *
;****************************************
proc1:		
        OUT    PORTA,AL			
	OUT    PORTB,AL			
	OUT    PORTC,AL			
	ret

;****************************************
;  ** move LED to LEFT 8 times
effet1:
	mov	al,1
	mov	bx,16
.b1:	mov	cx, 8
	;mov al,byte ptr ds:[100h]   ; use memory as variable 
.b2:	;out	0h, al					; any port to toggle the 74ls373
			
	; ln
			
	call	proc1
;	call	proc2
;	call	proc3
	; inc byte ptr ds:[100h]

	call	delay2
	rcl	al,1			
	loop	.b2

;  ** move LED to RIGHT 8 times
	mov	cx, 8
.b3:	rcr	al,1			

	;out	0h, al					; any port to toggle the 74ls373
			
	call	proc1
;	call	proc2
;	call	proc3
	; inc byte ptr ds:[100h]

	call	delay2
	loop	.b3

	dec	bx
	jnz	.b1
        ret

;*********************** ***********************

;****************************************
;* wait a sec...                        *
;****************************************
delay2:		
        push	dx
	push	bx
	mov 	bx,1FFFh 
.boucle:
	dec 	bx
	jnz 	.boucle
	pop		bx
	pop		dx
	ret
;*** END delay


; -------------------------------------------------------------------------------------------------

; ---- couleurs ANSI (memes constantes que uart_hello_2.asm) ---
ANSI_ROUGE:             db      27,'[31m',0
ANSI_VERT:              db      27,'[32m',0
ANSI_BLEU:              db      27,'[34m',0
ANSI_JAUNE:             db      27,'[33m',0
ANSI_BLANC:             db      27,'[0m',0      ; reset
CLS:                    db      27,'[2J',27,'[H',0

; --- table de conversion hexadecimale -------------------------
hex_table:              db      '0123456789ABCDEF'

; ---- messages ---------------------------------------------------
txt_crlf:               db      13,10,0
txt_ok_court:           db      'OK',27,'[0m',13,10,0
txt_defaut_court:       db      'DEFAUT',27,'[0m',13,10,0
txt_attendu:            db      '  attendu=',0
txt_lu:                 db      '  lu=',0
txt_defaut_detail:      db      '  >> DEFAUT memoire @ ',0

txt_banniere1:          db      27,'[0m','=== Test RAM 128K (VE2CUY, rapport UART 9600 8N1) ===',27,'[0m',13,10,0
txt_banniere2:          db      'Plan: seg 0000h (00000h-0FFFFh, 64 blocs) + seg 1000h (10000h-1FBFFh, 63 blocs)',13,10,'1 Ko reserve a la pile: 1FC00h-1FFFFh (non teste)',13,10,13,10,0

txt_ram_ok:             db      27,'[32m','*** RAM OK - 130048 octets testes (127 blocs de 1 Ko), aucune erreur ***',27,'[0m',13,10,13,10,0
txt_ram_defaut:         db      27,'[31m','*** RAM DEFECTUEUSE - voir le detail des defauts ci-dessus ***',27,'[0m',13,10,13,10,0

txt_dump_banniere:      db      27,'[34m','=== Dump ROM - 16 premiers Ko, adresse reelle C000:0000-C000:3FF0 ===',27,'[0m',13,10
                        db      'Duree estimee a 9600 bauds: environ 83 secondes (~80 Ko de texte)',13,10,13,10,0

txt_dump_fin:            db      27,'[32m','*** Dump ROM termine ***',27,'[0m',13,10,13,10,0

txt_8255_init:           db      27,'[33m','*** Test des 8255, Init + effet1 ***',27,'[0m',13,10,13,10,0

txt_auteur:             db      '8088 sur breadboard version 2026',13,10
                        db      'Par Alain Boudreault, aka VE2CUY',13,10
                        db      '--------------------------------',13,10,13,10,0
; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
