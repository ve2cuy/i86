BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; solution-02.asm
; nasm -f bin solution-02.asm -o Z:\Partage\Alain\solution-02.bin
; ------------------------------------------------------------
; VARIANTE DE ram_test_uart_7.asm: elimine completement le latch
; externe (et son decodage d'adresse) en deplacant le signal UART
; sur PC7 - le port C du 8255, via son mode BSR (Bit Set/Reset).
;
; AVANTAGE PAR RAPPORT A solution-01.asm (PA7 partage avec le LCD):
; le mode BSR permet de mettre a 1 ou a 0 UN SEUL bit du port C par
; une seule ecriture sur le registre de commande - le 8255 isole ce
; bit EN MATERIEL, les 7 autres ne sont jamais touches. Contrairement
; au port A, AUCUNE copie fantome en RAM n'est necessaire, et le LCD
; (toujours sur le port A) n'est absolument pas touche par ce
; changement - lcd_strobe reste identique a ram_test_uart_7.asm.
;
; Format BSR attendu par le 8255 sur le registre de commande (PIO):
;   bit7=0 (distingue un mot BSR d'un mot de mode, qui a bit7=1)
;   bits1-3 = numero du bit de port C (0-7)
;   bit0    = 1 pour mettre le bit a 1, 0 pour le mettre a 0
; Voir bsr_write plus bas.
;
; DEUX DETAILS IMPORTANTS proviennent du fait que le port C est deja
; utilise par effet1 (l'animation "chenillard" de l'etape 1):
;
; 1) effet1 fait des OUT PORTC complets (proc1) qui utilisent TOUS
;    les bits du port C, y compris PC7, pour faire deplacer une
;    seule LED d'un bout a l'autre. Rien ne change a cette animation
;    (on ne l'ampute pas d'un bit), mais ca veut dire que PC7 se
;    retrouve dans un etat quelconque une fois l'animation terminee.
;    Comme aucune transmission UART n'a lieu PENDANT effet1, ce n'est
;    pas un probleme - mais il faut explicitement remettre la ligne
;    UART au repos (idle=1) via bsr_write juste APRES effet1, a
;    chaque cycle (voir .temp: plus bas).
;
; 2) Comme pour solution-01.asm: un mot de MODE du 8255 (celui envoye
;    par init_8255) remet TOUS les verrous de sortie a 0, y compris
;    le port C au complet - donc la ligne UART aussi. Comme ce mot
;    n'a besoin d'etre envoye qu'une seule fois (le mode ne change
;    jamais), init_8255 est appele UNE SEULE FOIS avant la boucle
;    .ici (suggestion d'Alain), ce qui evite d'avoir a re-forcer
;    l'idle UART a chaque cycle pour CETTE raison-la (il reste
;    necessaire de le refaire apres effet1, pour la raison (1)).
;
; ATTENTION TIMING: bsr_write ajoute quelques instructions de plus
; qu'un simple "out" direct (mais PAS d'acces RAM, contrairement a
; porta_write dans solution-01.asm - un peu moins de surcharge).
; La calibration UART_BIT_COUNT=17 (mesuree avec un "out" direct
; dans uart_hello_2.asm) reste a RE-MESURER a l'analyseur logique.
;
; Cablage LCD (Port A du 8255, PA0-PA7): identique a lcd_hello_6.asm,
; INCHANGE - PA0-PA3 -> D4-D7, PA4 -> RS, PA6 -> E, R/W a la masse.
; Cablage UART: PC7 du 8255 (remplace le latch/74LS373 externe).
; ------------------------------------------------------------
STACK_SEG       equ     1000h

UART_PC_BIT     equ     7               ; numero du bit de port C (0-7)
                                         ; utilise pour l'UART (PC7)
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

; ------------------------------------------------------------
; LCD (HD44780, 4 bits) sur le Port A du 8255 - INCHANGE par
; rapport a ram_test_uart_7.asm (le port A n'est pas touche par
; cette solution).
; ------------------------------------------------------------
LCD_RS          equ     00010000b       ; bit4
LCD_E           equ     01000000b       ; bit6
LCD_E_MASK_OFF  equ     10111111b       ; pour effacer le bit E (AND)

%macro cls 0
        mov     si, CLS         ; efface l'ecran du terminal (ANSI)
        call    uart_tx_string
%endmacro

; UART_BIT_COUNT: valeur validee POUR UN "OUT" DIRECT (uart_hello_2.asm,
; latch/port dedie). A RE-MESURER avec ce montage (voir la note de
; timing au debut du fichier) - bsr_write ajoute de la surcharge
; (un peu moins que porta_write de solution-01.asm).
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

        call    init_8255       ; UNE SEULE FOIS (voir la note en en-tete) -
                                 ; configure les 3 ports en sortie, et remet
                                 ; le port C au complet a 0 en materiel

        mov     al, 1           ; ligne UART au repos (MARK) des le depart
        mov     bl, UART_PC_BIT
        call    bsr_write

.ici:
        cls                     ; efface l'ecran du terminal (ANSI)
        mov     si, txt_auteur
        call    uart_tx_string
        mov     cx, SECONDE     ; pause de 1 seconde avant de débuter le test (permet de voir le message de depart)
        call    delay_ms

.temp:
        mov     si, txt_8255_init
        call    uart_tx_string
        call    lcd_init        ; (re)initialise le LCD a chaque cycle (Clear Display inclus)
                                 ; (init_8255 n'est PLUS appele ici - voir start:)

        ; --- Etape 1: test du 8255 (animation sur le Port C) ---
        mov     si, lcd_txt_step1_l1
        call    lcd_show_line1
        mov     si, lcd_txt_step1_l2
        call    lcd_show_line2
        call    effet1

        ; --- effet1 utilise TOUS les bits du port C (dont PC7) pour
        ; son chenillard - on remet la ligne UART au repos juste
        ; apres, avant toute transmission (voir point (1) en en-tete) ---
        mov     al, 1
        mov     bl, UART_PC_BIT
        call    bsr_write
;        jmp     .temp

        ; --- Etape 2: test de la RAM (ligne 2 mise a jour a chaque bloc) ---
        mov     si, lcd_txt_step2_l1
        call    lcd_show_line1
        mov     si, lcd_txt_step2_l2
        call    lcd_show_line2

        call    test_ram        ; teste toute la RAM (128K) et rapporte via UART+LCD

        ; --- Etape 3: dump de la ROM ---
        mov     si, lcd_txt_step3_l1
        call    lcd_show_line1
        mov     si, lcd_txt_step3_l2
        call    lcd_show_line2

        call    rom_dump        ; dump des 16 premiers Ko de la ROM - voir plus bas

        mov     cx, 2 * SECONDE ; pause de 2 secondes avant de relancer un cycle
        call    delay_ms
        jmp     .ici            ; reboucle indefiniment

; ============================================================
; test_ram
; Teste la totalite de la RAM statique de 128K (00000h-1FFFFh),
; par blocs de 64K (2 segments: 0000h et 1000h), moins le
; dernier Ko du segment 1000h reserve a la pile active.
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

        call    msg_bloc_progression    ; affiche ES:debut-ES:fin + OK/DEFAUT
                                         ; (UART) + adresse+OK/ERR (LCD ligne 2),
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
; ce montage). Limite a ROM_DUMP_SIZE = 1000h (4 Ko) plus UNE
; ligne separee pour les 16 DERNIERS octets de la ROM (vecteur de
; reset + signature), a F000h:FFF0h (hors de portee de CS:offset).
;
; La ligne 2 du LCD suit la progression: a CHAQUE ligne envoyee
; sur l'UART, dump_line y affiche l'adresse ES:DI de cette ligne.
; ============================================================
ROM_DUMP_SIZE           equ     1000h           ; 4 Ko a dumper depuis le debut
ROM_LAST_LINE_SEG       equ     0F000h          ; segment pour les 16 derniers octets
ROM_LAST_LINE_OFF       equ     0FFF0h          ; F000h:FFF0h = physique FFFF0h

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
        call    dump_line               ; affiche ES:DI (UART+LCD), avance DI de 16
        cmp     di, ROM_DUMP_SIZE       ; les 4 Ko demandes sont-ils affiches ?
        jb      .line_loop

        ; --- ligne separee: les 16 DERNIERS octets de la ROM ---
        mov     ax, ROM_LAST_LINE_SEG
        mov     es, ax
        mov     di, ROM_LAST_LINE_OFF
        call    dump_line

        call    msg_dump_fin

        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; dump_line
; Affiche UNE ligne de 16 octets, a la fois sur l'UART (format
; complet: adresse/hexa/ascii) et sur la ligne 2 du LCD (adresse
; seulement: "SSSS:OOOO", complete a 16 caracteres).
;
; Entree:  ES:DI = adresse de depart de la ligne (16 octets)
; Sortie:  DI avance de 16 (adresse de la ligne suivante)
; ============================================================
dump_line:
        ; --- LCD: adresse de cette ligne (avant de l'envoyer sur l'UART,
        ; pour que le LCD annonce le bloc au moment ou il part) ---
        call    lcd_line2
        mov     ax, es
        call    lcd_tx_hex_word
        mov     al, ':'
        call    lcd_data
        mov     ax, di
        call    lcd_tx_hex_word
        mov     si, lcd_txt_dump_pad    ; complete a 16 caracteres (9 utilises)
        call    lcd_print

        ; --- UART: adresse reelle ES:DI ---
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
        ret

; ============================================================
; uart_tx_string / uart_tx_byte / uart_bit_delay / delay_ms
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

; uart_tx_byte: transmet AL (8N1) via bsr_write, qui ne touche
; QUE le bit PC7 (mode BSR - isolation materielle, pas de copie
; fantome necessaire). BX doit survivre a cet appel (test_segment y
; garde l'octet original pendant tout le cycle test-restauration) -
; meme discipline que uart_tx_hex_nibble/byte/word: on sauve/
; restaure BX ici puisqu'on utilise BL en interne pour choisir le
; bit de port C.
uart_tx_byte:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     dl, al          ; DL = copie de l'octet a transmettre
        mov     bl, UART_PC_BIT ; numero de bit pour toute la duree de cet octet

        mov     al, 0           ; --- bit de start ---
        call    bsr_write
        call    uart_bit_delay

        mov     cl, 8           ; --- 8 bits de donnees, LSB en premier ---
.bitloop:
        mov     al, dl
        and     al, 00000001b   ; AL = 0 ou 1 - exactement ce que bsr_write attend
        call    bsr_write
        call    uart_bit_delay

        shr     dl, 1
        dec     cl
        jnz     .bitloop

        mov     al, 1           ; --- bit de stop / idle (MARK = 1) ---
        call    bsr_write
        call    uart_bit_delay

        pop     dx
        pop     cx
        pop     bx
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
;   UART: "SEG:debut-SEG:fin <vert>OK<blanc>"  (ou <rouge>DEFAUT)
;   LCD (ligne 2, 16 car. exactement): "SSSS:OOOO OK    " ou
;        "SSSS:OOOO ERR   "
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
        ; --- meme information (adresse de debut + OK/ERR), condensee
        ; sur 16 caracteres, sur la ligne 2 du LCD ---
        call    lcd_line2

        mov     ax, es
        call    lcd_tx_hex_word
        mov     al, ':'
        call    lcd_data
        mov     ax, di
        sub     ax, 0400h       ; meme calcul que ci-dessus: debut du bloc
        call    lcd_tx_hex_word
        mov     al, ' '
        call    lcd_data
        ; -> 10 caracteres affiches jusqu'ici (4+1+4+1)

        cmp     bp, 0
        je      .lcd_ok
        mov     si, lcd_txt_err ; "ERR   " - 6 caracteres, complete a 16
        call    lcd_print
        jmp     .lcd_fin
.lcd_ok:
        mov     si, lcd_txt_ok  ; "OK    " - 6 caracteres, complete a 16
        call    lcd_print
.lcd_fin:

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
        MOV    AL,MASQUE_PIO  ; PORT A,B ET C EN SORTIE
        OUT    PIO,AL         ; CMD LA 8255
        MOV    AL,0
        OUT    PORTA,AL
        OUT    PORTB,AL
        OUT    PORTC,AL

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
;* proc1 - N'ecrit que sur le Port C
; (voir la note en en-tete: son ecriture complete inclut PC7,
; c'est pour ca qu'on reimpose l'idle UART juste apres effet1)
;****************************************
proc1:
        OUT    PORTC,AL
	ret

;****************************************
;  ** move LED to LEFT 8 times
effet1:
	mov	al,1
	mov	bx,16
.b1:	mov	cx, 8
.b2:
	call	proc1
	call	delay2
	rcl	al,1
	loop	.b2

;  ** move LED to RIGHT 8 times
	mov	cx, 8
.b3:	rcr	al,1
	call	proc1
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

; ============================================================
; bsr_write
; Definit ou efface UN SEUL bit du port C du 8255, via le mode
; BSR (Bit Set/Reset) du composant - AUCUNE copie fantome
; necessaire: le 8255 isole ce bit EN MATERIEL, les 7 autres ne
; sont jamais touches (contrairement au port A - voir solution-01.asm
; et sa copie fantome en RAM). Le port C doit deja etre configure
; en sortie via le mot de mode habituel (fait une seule fois par
; init_8255 - voir la note en en-tete de ce fichier).
;
; Format attendu par le 8255 sur le registre de commande (PIO):
;   bit7=0 (distingue un mot BSR d'un mot de mode, qui a bit7=1)
;   bits1-3 = numero du bit de port C (0-7)
;   bit0    = 1 pour mettre le bit a 1, 0 pour le mettre a 0
;
; Entree: AL = 0 ou 1 (valeur voulue du bit), BL = numero du bit (0-7)
; Sortie: AL et BL inchanges
; ============================================================
bsr_write:
        push    ax
        push    cx

        mov     cl, bl
        shl     cl, 1           ; numero de bit -> bits1-3 (1 seul decalage:
                                 ; SHL reg,1 est le seul autorise sur un 8086)
        mov     ah, al          ; AH = S/R (0 ou 1) -> ira sur le bit0
        mov     al, cl
        or      al, ah          ; combine bit select + S/R (bit7 reste a 0
                                 ; puisque BL <= 7, donc CL <= 14 = 00001110b)
        out     PIO, al         ; ecriture BSR sur le registre de commande

        pop     cx
        pop     ax
        ret

; -------------------------------------------------------------------------------------------------
; Section suivante: LCD (HD44780, 4 bits, Port A du 8255) - INCHANGE
; par rapport a ram_test_uart_7.asm (cette solution ne touche pas
; du tout au port A).
; -------------------------------------------------------------------------------------------------

; ============================================================
; lcd_init
; Sequence d'initialisation standard HD44780 en mode 4 bits.
; ============================================================
lcd_init:
        push    ax

        call    lcd_powerup_delay      ; >= 15-40ms apres mise sous tension

        mov     al, 0011b
        call    lcd_strobe
        call    lcd_delay_long         ; >= 4.1ms

        mov     al, 0011b
        call    lcd_strobe
        call    lcd_delay              ; >= 100us

        mov     al, 0011b
        call    lcd_strobe
        call    lcd_delay

        mov     al, 0010b              ; bascule reellement en mode 4 bits
        call    lcd_strobe
        call    lcd_delay

        ; A partir d'ici, le LCD attend 2 quartets (fort puis faible) par
        ; octet: on peut utiliser lcd_command/lcd_data normalement.
        mov     al, 00101000b          ; Function Set: 4 bits, 2 lignes, police 5x8
        call    lcd_command

        mov     al, 00001100b          ; Display ON, curseur OFF, clignotement OFF
        call    lcd_command

        mov     al, 00000110b          ; Entry Mode: incremente, pas de decalage
        call    lcd_command

        mov     al, 00000001b          ; Clear Display
        call    lcd_command
        call    lcd_delay_long         ; Clear Display est plus lent (>= 1.52ms)

        pop     ax
        ret

; ============================================================
; lcd_command / lcd_data
; ============================================================
lcd_command:
        push    ax
        push    cx

        mov     ch, al
        mov     al, ch
        mov     cl, 4
        shr     al, cl          ; get the high nibble (quartet fort)
        and     al, 00001111b   ; quartet fort -> bits0-3 (RS=0: rien a ajouter)
        call    lcd_strobe

        mov     al, ch
        and     al, 00001111b   ; quartet faible
        call    lcd_strobe

        pop     cx
        pop     ax
        call    lcd_delay
        ret

lcd_data:
        push    ax
        push    cx
        mov     ch, al
        mov     cl, 4

        mov     al, ch
        shr     al, cl
        and     al, 00001111b
        or      al, LCD_RS      ; RS=1: c'est une donnee (caractere)
        call    lcd_strobe

        mov     al, ch
        and     al, 00001111b
        or      al, LCD_RS
        call    lcd_strobe

        pop     cx
        pop     ax
        call    lcd_delay
        ret

; ============================================================
; lcd_strobe
; INCHANGE par rapport a ram_test_uart_7.asm: ecrit directement
; sur le port A (out PORTA,al) - aucun partage a gerer ici, l'UART
; est entierement sur le port C dans cette solution.
; Entree: AL = quartet + RS (E et R/W a 0)
; ============================================================
lcd_strobe:
        push    ax
        out     PORTA, al       ; pose RS + le quartet, E=0 (etat de repos)
        nop                     ; attend un peu avant de lever E (front montant)
        nop
        nop
        or      al, LCD_E       ; E=1
        out     PORTA, al
        call    lcd_short_delai ; largeur d'impulsion E (>= ~450ns, tres large marge)
        and     al, LCD_E_MASK_OFF  ; E=0 -> front descendant: le LCD capture ICI
        out     PORTA, al
        call    lcd_short_delai
        pop     ax
        ret

; ============================================================
; lcd_print
; ============================================================
lcd_print:
        push    ax
        push    si
.next_char:
        mov     al, [si]
        cmp     al, 0
        je      .done
        call    lcd_data
        inc     si
        jmp     .next_char
.done:
        pop     si
        pop     ax
        ret

; ============================================================
; lcd_line1 / lcd_line2
; ============================================================
lcd_line1:
        push    ax
        mov     al, 10000000b   ; Set DDRAM Address = 80h | 00h
        call    lcd_command
        pop     ax
        ret

lcd_line2:
        push    ax
        mov     al, 11000000b   ; Set DDRAM Address = 80h | 40h
        call    lcd_command
        pop     ax
        ret

; ============================================================
; lcd_show_line1 / lcd_show_line2
; ============================================================
lcd_show_line1:
        call    lcd_line1
        call    lcd_print
        ret

lcd_show_line2:
        call    lcd_line2
        call    lcd_print
        ret

; ============================================================
; lcd_tx_hex_nibble / lcd_tx_hex_byte / lcd_tx_hex_word
; ============================================================
lcd_tx_hex_nibble:
        push    bx
        and     al, 0Fh
        mov     bl, al
        xor     bh, bh
        mov     al, [hex_table + bx]
        call    lcd_data
        pop     bx
        ret

lcd_tx_hex_byte:
        push    bx
        mov     bl, al
        mov     al, bl
        shr     al, 1
        shr     al, 1
        shr     al, 1
        shr     al, 1
        call    lcd_tx_hex_nibble
        mov     al, bl
        call    lcd_tx_hex_nibble
        pop     bx
        ret

lcd_tx_hex_word:
        push    bx
        mov     bx, ax
        mov     al, bh
        call    lcd_tx_hex_byte
        mov     al, bl
        call    lcd_tx_hex_byte
        pop     bx
        ret

; ============================================================
; Delais LCD
; ============================================================
lcd_short_delai:        ; impulsion E / temps de setup-hold RS
        push    bx
        mov     bx, 0020h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_delay:               ; execution normale d'une commande/donnee (~40us typique)
        push    bx
        mov     bx, 0200h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_delay_long:          ; Clear/Home (>=1.52ms) et etapes du reveil 4 bits (>=4.1ms)
        push    bx
        mov     bx, 4000h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_powerup_delay:       ; >= 15-40ms apres mise sous tension - grande marge
        push    cx
        mov     cx, 0020h
.rep:
        push    cx
        call    lcd_delay_long
        pop     cx
        loop    .rep
        pop     cx
        ret

; -------------------------------------------------------------------------------------------------

; ---- couleurs ANSI ---
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

txt_banniere1:          db      27,'[0m','=== Test RAM 128K (VE2CUY, rapport UART 9600 8N1, PC7/BSR) ===',27,'[0m',13,10,0
txt_banniere2:          db      'Plan: seg 0000h (00000h-0FFFFh, 64 blocs) + seg 1000h (10000h-1FBFFh, 63 blocs)',13,10,'1 Ko reserve a la pile: 1FC00h-1FFFFh (non teste)',13,10,13,10,0

txt_ram_ok:             db      27,'[32m','*** RAM OK - 130048 octets testes (127 blocs de 1 Ko), aucune erreur ***',27,'[0m',13,10,13,10,0
txt_ram_defaut:         db      27,'[31m','*** RAM DEFECTUEUSE - voir le detail des defauts ci-dessus ***',27,'[0m',13,10,13,10,0

txt_dump_banniere:      db      27,'[34m','=== Dump ROM - 4 premiers Ko (C000:0000-C000:0FF0) + 16 derniers octets (F000:FFF0) ===',27,'[0m',13,10
                        db      'Duree estimee a 9600 bauds: environ 21 secondes',13,10,13,10,0

txt_dump_fin:            db      27,'[32m','*** Dump ROM termine ***',27,'[0m',13,10,13,10,0

txt_8255_init:           db      27,'[33m','*** Test des 8255 (effet1) - solution-02: UART sur PC7/BSR ***',27,'[0m',13,10,13,10,0

txt_auteur:             db      '8088 sur breadboard version 2026',13,10
                        db      'Par Alain Boudreault, aka VE2CUY',13,10
                        db      '--------------------------------',13,10,13,10,0

; ---- textes LCD (16 caracteres, complete automatiquement par des
; ---- espaces via "times" ----
lcd_txt_step1_l1:       db      '1-Test 8255'
                        times   16-($-lcd_txt_step1_l1) db ' '
                        db      0
lcd_txt_step1_l2:       db      'Port C: anime'
                        times   16-($-lcd_txt_step1_l2) db ' '
                        db      0

lcd_txt_step2_l1:       db      '2-Test RAM'
                        times   16-($-lcd_txt_step2_l1) db ' '
                        db      0
lcd_txt_step2_l2:       db      'En attente...'
                        times   16-($-lcd_txt_step2_l2) db ' '
                        db      0

lcd_txt_step3_l1:       db      '3-Dump ROM'
                        times   16-($-lcd_txt_step3_l1) db ' '
                        db      0
lcd_txt_step3_l2:       db      'Dump 4K+16oct.'
                        times   16-($-lcd_txt_step3_l2) db ' '
                        db      0

; ---- complement de 7 espaces utilise par dump_line ----
lcd_txt_dump_pad:
                        times   7 db ' '
                        db      0

; ---- "queues" de 6 caracteres utilisees par msg_bloc_progression ----
lcd_txt_ok:             db      'OK'
                        times   6-($-lcd_txt_ok) db ' '
                        db      0
lcd_txt_err:            db      'ERR'
                        times   6-($-lcd_txt_err) db ' '
                        db      0

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
