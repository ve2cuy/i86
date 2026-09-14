BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; solution-01.asm
; nasm -f bin solution-01.asm -o Z:\Partage\Alain\solution-01.bin
; (voir aussi le Makefile: "make rom" fait la meme chose et copie
; le resultat vers Z:\Partage\Alain\rom.bin)
; ------------------------------------------------------------
; VARIANTE DE ram_test_uart_7.asm: elimine completement le latch
; externe (et son decodage d'adresse) en deplacant le signal UART
; sur PA7 - le meme port que le LCD (Port A du 8255).
;
; PROBLEME: en mode 0, le 8255 n'adresse PAS les bits du port A
; individuellement - un OUT ecrit les 8 bits en meme temps. Le LCD
; (D4-D7, RS, E sur PA0-PA4/PA6) et l'UART (PA7) doivent donc
; cohabiter sur le MEME octet. Solution: une copie "fantome" de
; l'etat du port A est gardee en RAM (PORTA_SHADOW - impossible en
; ROM, qui est en lecture seule), et CHAQUE ecriture - LCD ou UART -
; passe par porta_write, qui ne modifie QUE les bits qui la
; concernent et preserve les autres via un lecture-modification-
; ecriture (voir lib/common.asm). La ligne UART reste donc a son
; dernier etat (idle ou en cours de bit) meme quand le LCD ecrit, et
; vice-versa.
;
; La copie fantome vit dans la zone deja reservee a la pile (voir
; test_ram plus bas) - donc AUCUN octet en plus n'est retire du
; test RAM.
;
; IMPORTANT - init_8255 sorti de la boucle principale: un mot de
; mode du 8255 (comme celui envoye par init_8255) remet TOUS les
; verrous de sortie a 0, y compris le port A au complet (LCD ET
; UART). Comme ce mot n'a besoin d'etre envoye qu'une seule fois
; (le mode ne change jamais ensuite), init_8255 est maintenant
; appele UNE SEULE FOIS avant la boucle .ici, pas a chaque cycle -
; sinon la ligne UART retomberait a 0 (condition de break) a
; chaque nouveau cycle, le temps que le LCD la remette par hasard
; au bon etat via un premier appel a lcd_strobe.
;
; Cablage LCD (Port A du 8255, PA0-PA7): identique a lcd_hello_6.asm
;   PA0-PA3 -> D4-D7, PA4 -> RS, PA6 -> E, R/W du LCD a la masse.
;   PA7 -> UART (remplace le latch/74LS373 externe).
;
; LCD 4x20 (remplace le 2x16 d'origine). Adressage DDRAM utilise
; pour les lignes 3/4 (convention standard des afficheurs 20x4 base
; sur le HD44780: la ligne 3 est en fait la suite de la ligne 1 en
; memoire interne, et la ligne 4 la suite de la ligne 2):
; ligne1=00h, ligne2=40h, ligne3=14h, ligne4=54h ("type A" - si le
; texte des lignes 3/4 apparait au mauvais endroit sur ton module,
; il existe une variante moins courante 00h/20h/40h/60h a essayer).
; Le Function Set (00101000b: 4 bits, N=1) ne change PAS: le HD44780
; ne connait que le mode "1 ligne" ou "2 lignes" en interne.
;
; ------------------------------------------------------------
; STRUCTURE DU PROJET (voir Directives.md):
;   solution-01.asm       - ce fichier: flux principal (start, test
;                            RAM, dump ROM, animation 8255) + toutes
;                            les donnees/textes.
;   include/hardware.inc  - constantes materielles partagees (8255,
;                            adresses RAM des variables partagees).
;   include/delay.inc     - macro delay_ms.
;   lib/common.asm        - porta_write + hex_table (partages LCD/UART).
;   lib/lcd.asm           - toutes les procedures d'affichage LCD.
;   lib/uart.asm          - toutes les procedures de transmission UART.
;   lib/utils.asm         - delay_ms_proc (routine derriere la macro).
;
; Tous les %include de ce fichier (et de ceux de ./lib) sont ecrits
; comme des chemins relatifs a CETTE racine (Solution-01/) - voir
; la note dans include/hardware.inc. Le Makefile lance toujours nasm
; depuis cette racine, meme pour assembler un module seul.
; ------------------------------------------------------------
STACK_SEG       equ     1000h

SECONDE         equ     1000            ; 1 seconde = 1000 ms

%macro cls 0
        mov     si, CLS         ; efface l'ecran du terminal (ANSI)
        call    uart_tx_string
%endmacro

%include "include/hardware.inc"
%include "include/delay.inc"

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
                                 ; le port A au complet a 0 en materiel

        ; --- initialise la copie fantome du port A ET force la ligne
        ; UART au repos (MARK) des le depart - seule fois ou l'on ecrit
        ; le port A directement plutot que via porta_write, puisque
        ; c'est justement ce qui etablit l'etat de depart coherent ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, PORTA_SHADOW_OFF
        mov     al, UART_MASK   ; PA7=1 (idle), tout le reste a 0
        mov     [es:di], al
        out     PORTA, al

.ici:
        cls                     ; efface l'ecran du terminal (ANSI)
        mov     si, txt_auteur
        call    uart_tx_string
        delay_ms SECONDE        ; pause de 1 seconde avant de débuter le test (permet de voir le message de depart)

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
        mov     si, lcd_txt_step1_l4   ; texte fixe (ligne 3 = progression
        call    lcd_show_line4         ; live, mise a jour par effet1)
        call    effet1
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

        delay_ms (2*SECONDE)    ; pause de 2 secondes avant de relancer un cycle
        jmp     .ici            ; reboucle indefiniment

; ============================================================
; test_ram
; Teste la totalite de la RAM statique de 128K (00000h-1FFFFh),
; par blocs de 64K (2 segments: 0000h et 1000h), moins le
; dernier Ko du segment 1000h reserve a la pile active ET a la
; copie fantome du port A (PORTA_SHADOW_OFF = tout debut de cette
; zone, voir en en-tete).
; Resultat: 130048 octets testes sur 131072 (127 blocs de 1 Ko).
; ============================================================
test_ram:
        cli                     ; pas d'interruption pendant tout le test
                                 ; (encore plus important ici: protege aussi
                                 ; le timing bit a bit de l'UART)
        xor     bh, bh          ; BH = drapeau d'erreur GLOBAL (0 = RAM valide)
        xor     bp, bp          ; BP = drapeau d'erreur du BLOC courant

        ; --- remet a zero les compteurs de progression du LCD (ligne
        ; 4, etape 2) - vivent en RAM juste apres PORTA_SHADOW, voir
        ; en en-tete. ES/DI seront de toute facon rechargEs juste
        ; apres pour le premier segment: pas besoin de les sauver ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BLOCK_COUNTER_OFF
        mov     byte [es:di], 0
        mov     di, DEFECT_COUNTER_OFF
        mov     byte [es:di], 0

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
        mov     cx, 64512       ; 65536 - 1024 (zone reservee a la pile
                                 ; ET a PORTA_SHADOW, voir en en-tete)
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
; ce montage) - l'adresse imprimee ici correspond exactement a ce
; qu'on verrait avec un debogueur materiel (SEG:OFFSET reel).
;
; Limite a ROM_DUMP_SIZE = 1000h (4 Ko, 256 lignes) pour rester
; rapide. Ensuite, UNE ligne supplementaire est affichee pour les
; 16 DERNIERS octets de la ROM: c'est exactement le vecteur de
; reset (jmp C000h:0000h) suivi de la signature ' VE2CUY 26' - voir
; la fin du fichier.
;
; ATTENTION segment: le premier dump utilise ES=CS (C000h), qui ne
; peut adresser QUE les 64 Ko C0000h-CFFFFh. Les 16 DERNIERS octets
; de la ROM (256 Ko) sont a l'adresse physique FFFF0h-FFFFFh, hors
; de portee de CS:offset - on y accede avec le meme segment que le
; vecteur de reset materiel du 8088: F000h:FFF0h.
;
; La ligne 2 du LCD suit la progression: a CHAQUE ligne envoyee
; sur l'UART, dump_line y affiche l'adresse ES:DI de cette ligne.
; ============================================================
ROM_DUMP_SIZE           equ     1000h           ; 4 Ko a dumper depuis le debut
ROM_LAST_LINE_SEG       equ     0F000h          ; segment pour les 16 derniers octets
ROM_LAST_LINE_OFF       equ     0FFF0h          ; F000h:FFF0h = physique FFFF0h

rom_dump:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        call    msg_dump_banniere

        mov     ax, cs
        mov     es, ax          ; ES = segment materiel REEL (CS), affiche tel quel

        xor     di, di
        mov     bx, 1           ; BX = numero de ligne courante (1-based),
                                 ; passe a dump_line pour la ligne 4 du LCD
.line_loop:
        call    dump_line               ; affiche ES:DI (UART+LCD), avance DI de 16
        inc     bx
        cmp     di, ROM_DUMP_SIZE       ; les 4 Ko demandes sont-ils affiches ?
        jb      .line_loop

        ; --- ligne separee: les 16 DERNIERS octets de la ROM ---
        mov     ax, ROM_LAST_LINE_SEG
        mov     es, ax
        mov     di, ROM_LAST_LINE_OFF
        mov     bx, 257         ; derniere ligne logique (256 + celle-ci)
        call    dump_line

        call    msg_dump_fin

        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; dump_line
; Affiche UNE ligne de 16 octets:
;   UART: format complet (adresse/hexa/ascii) - INCHANGE
;   LCD (4x20):
;     ligne 2 = adresse "SSSS:OOOO"
;     ligne 3 = apercu des 7 premiers octets en hexadecimal
;     ligne 4 = "Ligne: NNN/257"
;
; Entree:  ES:DI = adresse de depart de la ligne (16 octets)
;          BX = numero de cette ligne (1-257, prepare par rom_dump)
; Sortie:  DI avance de 16 (adresse de la ligne suivante), BX inchange
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
        mov     si, lcd_txt_dump_pad    ; complete a 20 caracteres (9 utilises)
        call    lcd_print

        ; --- Ligne 3 du LCD: apercu des 7 premiers octets en hexa
        ; (7*2 chiffres + 6 espaces = 20 caracteres exactement) ---
        call    lcd_line3
        push    di              ; DI va temporairement avancer pour la lecture -
                                 ; restaure avant de continuer (l'appelant, et le
                                 ; bloc UART plus bas, ont besoin de la valeur
                                 ; d'origine)
        mov     cx, 7
.lcd_preview_loop:
        mov     al, [es:di]
        call    lcd_tx_hex_byte
        cmp     cx, 1
        je      .lcd_preview_last
        mov     al, ' '
        call    lcd_data
.lcd_preview_last:
        inc     di
        loop    .lcd_preview_loop
        pop     di

        ; --- Ligne 4 du LCD: numero de cette ligne / 257 (BX prepare
        ; par rom_dump) ---
        call    lcd_line4
        mov     si, lcd_txt_ligne_prefix
        call    lcd_print
        mov     ax, bx
        call    lcd_tx_dec3
        mov     si, lcd_txt_ligne_suffix
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
;   LCD (4x20):
;     ligne 2 = plage complete du bloc "SSSS:OOOO-SSSS:OOOO"
;     ligne 3 = etat en toutes lettres "Etat: OK" / "Etat: DEFAUT"
;     ligne 4 = compteurs cumulatifs "Bloc:NNN/127 Def:NNN"
; Entree: ES = segment courant, DI = offset JUSTE APRES le bloc
;         (multiple de 400h), BP = drapeau du bloc (0=ok, sinon defaut)
; Reinitialise BP a 0 avant de retourner.
; ============================================================
msg_bloc_progression:
        ; --- incremente les compteurs cumulatifs (bloc courant, et
        ; blocs defectueux si BP != 0) - vivent en RAM juste apres
        ; PORTA_SHADOW (voir en en-tete). ES:DI appartiennent a
        ; l'appelant (test_segment, en plein test) - sauvegardes et
        ; restaures ici, meme prudence que porta_write. ---
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BLOCK_COUNTER_OFF
        inc     byte [es:di]

        cmp     bp, 0
        je      .no_defect_incr
        mov     di, DEFECT_COUNTER_OFF
        inc     byte [es:di]
.no_defect_incr:
        pop     di
        pop     es

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
        ; --- Ligne 2 du LCD: plage complete du bloc "SSSS:OOOO-SSSS:OOOO",
        ; miroir exact de ce qui part sur l'UART (19 caracteres - avant,
        ; sur 16 colonnes, seule l'adresse de DEBUT tenait) ---
        call    lcd_line2

        mov     ax, es
        call    lcd_tx_hex_word
        mov     al, ':'
        call    lcd_data
        mov     ax, di
        sub     ax, 0400h       ; ax = debut du bloc (di - 1024)
        call    lcd_tx_hex_word

        mov     al, '-'
        call    lcd_data

        mov     ax, es
        call    lcd_tx_hex_word
        mov     al, ':'
        call    lcd_data
        mov     ax, di
        dec     ax              ; ax = fin du bloc (di - 1)
        call    lcd_tx_hex_word

        ; --- Ligne 3 du LCD: etat en toutes lettres ---
        call    lcd_line3
        cmp     bp, 0
        je      .lcd_ok
        mov     si, lcd_txt_etat_defaut
        call    lcd_print
        jmp     .lcd_etat_fin
.lcd_ok:
        mov     si, lcd_txt_etat_ok
        call    lcd_print
.lcd_etat_fin:

        ; --- Ligne 4 du LCD: compteurs cumulatifs "Bloc:NNN/127 Def:NNN"
        ; (20 caracteres exactement) - relit les deux compteurs
        ; incrementes au debut de cette routine ---
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BLOCK_COUNTER_OFF
        mov     dl, [es:di]     ; DL = numero de bloc courant
        mov     di, DEFECT_COUNTER_OFF
        mov     dh, [es:di]     ; DH = nombre de blocs defectueux
        pop     di
        pop     es

        call    lcd_line4
        mov     si, lcd_txt_bloc_prefix
        call    lcd_print
        mov     al, dl
        xor     ah, ah
        call    lcd_tx_dec3
        mov     si, lcd_txt_bloc_mid
        call    lcd_print
        mov     al, dh
        xor     ah, ah
        call    lcd_tx_dec3

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
;****************************************
proc1:
        OUT    PORTC,AL
	ret

;****************************************
;  ** move LED to LEFT 8 times
effet1:
	mov	al,1
	mov	bx,16
.b1:
        ; --- Ligne 3 du LCD: passe courante (1-16), mise a jour une
        ; fois par passe. AL (motif de LED en cours) doit survivre
        ; intact - BX (compteur de passes) est seulement LU ici, pas
        ; modifie, et les routines LCD le preservent de toute facon
        ; (meme discipline que porta_write/uart_tx_byte). ---
        push    ax
        call    lcd_line3
        mov     si, lcd_txt_passe_prefix
        call    lcd_print
        mov     ax, 17
        sub     ax, bx          ; ax = numero de passe courant (1..16)
        call    lcd_tx_dec3
        mov     si, lcd_txt_passe_suffix
        call    lcd_print
        pop     ax

	mov	cx, 8
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


; -------------------------------------------------------------------------------------------------
; Modules partages (LCD, UART, delay_ms) - voir Directives.md. Ces
; %include viennent APRES tout le code ci-dessus (qui appelle leurs
; procedures par reference avant, ce qui est normal: NASM resout
; les references avant comme apres dans un meme flux assemble) pour
; que start: reste le tout premier octet emis dans la ROM (contrainte
; du vecteur de reset materiel, voir reset_vector plus bas).
; -------------------------------------------------------------------------------------------------
%include "lib/common.asm"
%include "lib/lcd.asm"
%include "lib/uart.asm"
%include "lib/utils.asm"

; -------------------------------------------------------------------------------------------------
; Section suivante: donnees et textes
; -------------------------------------------------------------------------------------------------

; ---- couleurs ANSI ---
ANSI_ROUGE:             db      27,'[31m',0
ANSI_VERT:              db      27,'[32m',0
ANSI_BLEU:              db      27,'[34m',0
ANSI_JAUNE:             db      27,'[33m',0
ANSI_BLANC:             db      27,'[0m',0      ; reset
CLS:                    db      27,'[2J',27,'[H',0

; --- messages ---------------------------------------------------
txt_crlf:               db      13,10,0
txt_ok_court:           db      'OK',27,'[0m',13,10,0
txt_defaut_court:       db      'DEFAUT',27,'[0m',13,10,0
txt_attendu:            db      '  attendu=',0
txt_lu:                 db      '  lu=',0
txt_defaut_detail:      db      '  >> DEFAUT memoire @ ',0

txt_banniere1:          db      27,'[0m','=== Test RAM 128K (VE2CUY, rapport UART 9600 8N1, PA7) ===',27,'[0m',13,10,0
txt_banniere2:          db      'Plan: seg 0000h (00000h-0FFFFh, 64 blocs) + seg 1000h (10000h-1FBFFh, 63 blocs)',13,10,'1 Ko reserve a la pile + copie fantome PA7: 1FC00h-1FFFFh (non teste)',13,10,13,10,0

txt_ram_ok:             db      27,'[32m','*** RAM OK - 130048 octets testes (127 blocs de 1 Ko), aucune erreur ***',27,'[0m',13,10,13,10,0
txt_ram_defaut:         db      27,'[31m','*** RAM DEFECTUEUSE - voir le detail des defauts ci-dessus ***',27,'[0m',13,10,13,10,0

txt_dump_banniere:      db      27,'[34m','=== Dump ROM - 4 premiers Ko (C000:0000-C000:0FF0) + 16 derniers octets (F000:FFF0) ===',27,'[0m',13,10
                        db      'Duree estimee a 9600 bauds: environ 21 secondes',13,10,13,10,0

txt_dump_fin:            db      27,'[32m','*** Dump ROM termine ***',27,'[0m',13,10,13,10,0

txt_8255_init:           db      27,'[33m','*** Test des 8255 (effet1) - solution-01: UART sur PA7 ***',27,'[0m',13,10,13,10,0

txt_auteur:             db      '8088 sur breadboard version 2026',13,10
                        db      'Par Alain Boudreault, aka VE2CUY',13,10
                        db      '--------------------------------',13,10,13,10,0

; ---- textes LCD (20 caracteres, complete automatiquement par des
; ---- espaces via "times" - afficheur 4x20) ----
lcd_txt_step1_l1:       db      '1/3 - Test 8255'
                        times   20-($-lcd_txt_step1_l1) db ' '
                        db      0
lcd_txt_step1_l2:       db      'Chenillard Port C'
                        times   20-($-lcd_txt_step1_l2) db ' '
                        db      0
lcd_txt_step1_l4:       db      'VE2CUY 2026'
                        times   20-($-lcd_txt_step1_l4) db ' '
                        db      0

lcd_txt_step2_l1:       db      '2/3 - Test RAM 128K'
                        times   20-($-lcd_txt_step2_l1) db ' '
                        db      0
lcd_txt_step2_l2:       db      'En attente...'
                        times   20-($-lcd_txt_step2_l2) db ' '
                        db      0

lcd_txt_step3_l1:       db      '3/3 - Dump ROM'
                        times   20-($-lcd_txt_step3_l1) db ' '
                        db      0
lcd_txt_step3_l2:       db      'Dump 4K+16 octets'
                        times   20-($-lcd_txt_step3_l2) db ' '
                        db      0

; ---- complement de 11 espaces utilise par dump_line, apres les 9
; ---- caracteres d'adresse "SSSS:OOOO" (9+11=20) ----
lcd_txt_dump_pad:
                        times   11 db ' '
                        db      0

; ---- ligne 3 de l'etape 2 (msg_bloc_progression): etat en toutes
; ---- lettres, 20 caracteres ----
lcd_txt_etat_ok:        db      'Etat: OK'
                        times   20-($-lcd_txt_etat_ok) db ' '
                        db      0
lcd_txt_etat_defaut:    db      'Etat: DEFAUT'
                        times   20-($-lcd_txt_etat_defaut) db ' '
                        db      0

; ---- ligne 4 de l'etape 2: "Bloc:" + dec3 + "/127 Def:" + dec3 =
; ---- 5+3+9+3 = 20 caracteres EXACTEMENT (pas de padding requis) ----
lcd_txt_bloc_prefix:    db      'Bloc:', 0
lcd_txt_bloc_mid:       db      '/127 Def:', 0

; ---- ligne 3 de l'etape 1 (effet1): "Passe: " + dec3 + "/16" +
; ---- 7 espaces = 7+3+10 = 20 caracteres ----
lcd_txt_passe_prefix:   db      'Passe: ', 0
lcd_txt_passe_suffix:   db      '/16'
                        times   10-($-lcd_txt_passe_suffix) db ' '
                        db      0

; ---- ligne 4 de l'etape 3 (dump_line): "Ligne: " + dec3 + "/257" +
; ---- 6 espaces = 7+3+10 = 20 caracteres ----
lcd_txt_ligne_prefix:   db      'Ligne: ', 0
lcd_txt_ligne_suffix:   db      '/257'
                        times   10-($-lcd_txt_ligne_suffix) db ' '
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
