BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; solution-01.asm
; nasm -f bin solution-01.asm -o Z:\Partage\Alain\solution-01.bin
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
; ecriture (voir plus bas). La ligne UART reste donc a son dernier
; etat (idle ou en cours de bit) meme quand le LCD ecrit, et
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
; ATTENTION TIMING: porta_write fait plusieurs instructions de plus
; qu'un simple "out" direct (dont un acces RAM pour la copie
; fantome). La calibration UART_BIT_COUNT=17 (mesuree avec un "out"
; direct dans uart_hello_2.asm) n'est PROBABLEMENT PLUS exacte ici -
; a RE-MESURER a l'analyseur logique avant de faire confiance au
; debit reel. Comparer avec solution-02.asm (port C, mode BSR), qui
; a un peu moins de surcharge (pas d'acces RAM).
;
; Cablage LCD (Port A du 8255, PA0-PA7): identique a lcd_hello_6.asm
;   PA0-PA3 -> D4-D7, PA4 -> RS, PA6 -> E, R/W du LCD a la masse.
;   PA7 -> UART (nouveau - remplace le latch/74LS373 externe).
;
; MISE A JOUR - LCD 4x20 (remplace le 2x16): Alain a remplace
; l'afficheur par un modele 4 lignes x 20 caracteres. L'affichage
; des 3 etapes a ete entierement repense pour profiter de l'espace:
;
;   Etape 1 (test 8255): ligne 3 suit maintenant la progression de
;   l'animation en direct ("Passe: NNN/16"), ligne 4 = texte fixe.
;
;   Etape 2 (test RAM): ligne 2 affiche desormais la plage COMPLETE
;   du bloc (debut-fin, comme sur l'UART - avant, seule l'adresse de
;   debut tenait sur 16 caracteres). Ligne 3 = etat du bloc en toutes
;   lettres (OK/DEFAUT). Ligne 4 = nouveaux compteurs cumulatifs
;   (bloc courant/127, nombre de blocs ayant eu au moins un defaut) -
;   vivent en RAM juste apres PORTA_SHADOW (voir plus bas), remis a
;   zero au debut de chaque test_ram.
;
;   Etape 3 (dump ROM): ligne 3 = apercu des 7 premiers octets de la
;   ligne en cours (sur les 16 envoyes par l'UART). Ligne 4 = numero
;   de ligne courante/257 (256 lignes de 4 Ko + la ligne des 16
;   derniers octets).
;
; Adressage DDRAM utilise pour les lignes 3/4 (convention standard
; des afficheurs 20x4 base sur le HD44780: la ligne 3 est en fait la
; suite de la ligne 1 en memoire interne, et la ligne 4 la suite de
; la ligne 2): ligne1=00h, ligne2=40h, ligne3=14h, ligne4=54h. C'est
; la convention la plus repandue ("type A") - si le texte des lignes
; 3/4 apparait au mauvais endroit sur ton module, il existe une
; variante moins courante (00h/20h/40h/60h) a essayer a la place.
; Le Function Set (00101000b: 4 bits, N=1) ne change PAS: le HD44780
; ne connait que le mode "1 ligne" ou "2 lignes" en interne, un
; afficheur 4 lignes multiplexe simplement chaque ligne logique sur
; 2 lignes visibles.
; ------------------------------------------------------------
STACK_SEG       equ     1000h

UART_MASK       equ     10000000b       ; PA7 - masque pour porta_write:
                                         ; seul ce bit du port A est
                                         ; concerne par l'UART
UART_BIT_ON     equ     10000000b       ; valeur du bit UART a l'etat "1"
UART_IDLE       equ     10000000b       ; ligne au repos (MARK) = 1
SECONDE         equ     1000            ; 1 seconde = 1000 ms

; --- copie fantome du port A + compteurs de progression du test RAM:
; --- vivent dans la zone deja reservee a la pile (segment STACK_SEG,
; --- tout debut du dernier Ko non teste - voir "1 Ko reserve a la
; --- pile" dans test_ram). 3 octets utilises sur 1024 reserves. ---
VAR_SEG             equ     1000h
PORTA_SHADOW_OFF    equ     0FC00h
BLOCK_COUNTER_OFF   equ     0FC01h  ; numero du bloc courant (1-127)
DEFECT_COUNTER_OFF  equ     0FC02h  ; nombre de blocs ayant eu >=1 defaut

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
; LCD (HD44780, 4 bits) sur le Port A du 8255 - voir lcd_hello_6.asm
; pour le detail du cablage et de la validation sur ce montage.
; ------------------------------------------------------------
LCD_RS          equ     00010000b       ; bit4
LCD_E           equ     01000000b       ; bit6
LCD_E_MASK_OFF  equ     10111111b       ; pour effacer le bit E (AND, local a AL)
LCD_STROBE_MASK equ     01011111b       ; bits 0-4 et 6 (D4-D7,RS,E) - PAS bit7 (UART)

%macro cls 0
        mov     si, CLS         ; efface l'ecran du terminal (ANSI)
        call    uart_tx_string
%endmacro

; UART_BIT_COUNT: valeur VALIDEE sur ce montage (solution-01, UART
; sur PA7 via porta_write) - mesuree par Alain a l'analyseur
; logique: periode variant entre 106 et 110us (cible 104.17us pour
; 9600 bauds), affichage terminal stable et lisible.
;
; Historique de la calibration: le modele analytique derive de
; l'ancienne mesure (105us a N=17 avec un "out" direct, puis 164us
; au meme N=17 une fois porta_write ajoute -> ~59us de surcharge
; fixe, d'ou T(N) ~= 85.8 + 4.6*N us) predisait N=4 (~104.2us), mais
; N=3 s'est avere necessaire en pratique - le modele (base sur
; seulement 2 points) sous-estimait la surcharge reelle. Le leger
; jitter observe (quelques us de variation pour le meme N) est une
; caracteristique connue du 8088: sa file d'instructions (prefetch
; queue) se remplit de facon asynchrone par rapport a l'execution,
; ce qui fait varier legerement le nombre de cycles reels d'une
; boucle dec/jnz serree - un modele purement analytique ne peut pas
; le capturer parfaitement, d'ou l'importance de mesurer sur le vrai
; materiel plutot que de se fier au calcul seul.
; Ne pas modifier sans re-mesurer.
UART_BIT_COUNT  equ     3

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

        mov     cx, 2 * SECONDE ; pause de 2 secondes avant de relancer un cycle
        call    delay_ms
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
; ce montage) - contrairement a une version precedente qui
; affichait une adresse "logique" relative a 0000h, l'adresse
; imprimee ici correspond exactement a ce qu'on verrait avec un
; debogueur materiel (SEG:OFFSET reel).
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

; uart_tx_byte: transmet AL (8N1) via porta_write, qui ne touche
; que le bit PA7 (masque UART_MASK) et preserve le reste du port A
; (donc le LCD) via la copie fantome. BX doit survivre a cet appel
; (test_segment y garde l'octet original pendant tout le cycle
; test-restauration) - meme discipline que uart_tx_hex_nibble/byte
; /word: on sauve/restaure BX ici puisqu'on utilise BL en interne.
uart_tx_byte:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     dl, al          ; DL = copie de l'octet a transmettre
        mov     bl, UART_MASK   ; masque Port A pour toute la duree de cet octet

        mov     al, 0           ; --- bit de start ---
        call    porta_write
        call    uart_bit_delay

        mov     cl, 8           ; --- 8 bits de donnees, LSB en premier ---
.bitloop:
        mov     al, dl
        and     al, 00000001b
        cmp     al, 0
        je      .bit_zero
        mov     al, UART_BIT_ON
        jmp     .send_bit
.bit_zero:
        mov     al, 0
.send_bit:
        call    porta_write
        call    uart_bit_delay

        shr     dl, 1
        dec     cl
        jnz     .bitloop

        mov     al, UART_IDLE   ; --- bit de stop ---
        call    porta_write
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
; Section suivante: LCD (HD44780, 4 bits, Port A du 8255) + partage
; du port avec l'UART (PA7) via porta_write.
; -------------------------------------------------------------------------------------------------

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
; Envoient un octet complet au LCD en 2 quartets (fort puis
; faible). lcd_command: RS=0. lcd_data: RS=1 (caractere).
; Entree: AL = octet a envoyer. CX est utilise en interne (et
; restaure) - sans danger a appeler depuis test_segment.
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
; Envoie UN quartet deja pret. Genere l'impulsion E (front
; descendant = capture reelle par le LCD). Passe maintenant par
; porta_write (masque LCD_STROBE_MASK) au lieu d'un "out" direct,
; pour ne jamais toucher au bit UART (PA7) du port A.
; Entree: AL = quartet + RS (E et R/W a 0)
; ============================================================
lcd_strobe:
        push    ax
        push    bx              ; preserve le BX de l'appelant (ex: test_segment y
                                 ; garde l'octet original pendant tout le cycle
                                 ; test-restauration) - meme discipline que
                                 ; uart_tx_hex_nibble/byte/word, necessaire depuis
                                 ; que BL sert de masque pour porta_write
        mov     bl, LCD_STROBE_MASK
        call    porta_write     ; pose RS + le quartet, E=0 (etat de repos)
        nop                     ; attend un peu avant de lever E (front montant)
        nop
        nop
        or      al, LCD_E       ; E=1
        call    porta_write
        call    lcd_short_delai ; largeur d'impulsion E (>= ~450ns, tres large marge)
        and     al, LCD_E_MASK_OFF  ; E=0 -> front descendant: le LCD capture ICI
        call    porta_write
        call    lcd_short_delai
        pop     bx
        pop     ax
        ret

; ============================================================
; lcd_print
; Affiche une chaine terminee par 00h (PAS de padding - le
; texte doit deja avoir la largeur voulue). Entree: DS:SI.
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
; lcd_line1 / lcd_line2 / lcd_line3 / lcd_line4
; Positionnement DDRAM pour un afficheur 4x20: la ligne 3 est en
; fait la suite de la ligne 1 en memoire interne (00h puis 14h), et
; la ligne 4 la suite de la ligne 2 (40h puis 54h) - convention
; standard ("type A") des afficheurs 20x4 bases sur le HD44780.
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

lcd_line3:
        push    ax
        mov     al, 10010100b   ; Set DDRAM Address = 80h | 14h
        call    lcd_command
        pop     ax
        ret

lcd_line4:
        push    ax
        mov     al, 11010100b   ; Set DDRAM Address = 80h | 54h
        call    lcd_command
        pop     ax
        ret

; ============================================================
; lcd_show_line1 / lcd_show_line2 / lcd_show_line3 / lcd_show_line4
; ============================================================
lcd_show_line1:
        call    lcd_line1
        call    lcd_print
        ret

lcd_show_line2:
        call    lcd_line2
        call    lcd_print
        ret

lcd_show_line3:
        call    lcd_line3
        call    lcd_print
        ret

lcd_show_line4:
        call    lcd_line4
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
; lcd_tx_dec3
; Affiche AX (0-999) en decimal, TOUJOURS 3 chiffres avec des
; zeros de tete (ex: 7 -> "007", 257 -> "257"). Detruit AX/BX/CX/
; DX - jamais SI/DI/ES/BP (meme discipline que les routines hex).
; Utilise pour les compteurs de l'etape 2 (blocs/defauts, 0-127) et
; de l'etape 3 (numero de ligne, 1-257) sur le LCD 4x20.
; ============================================================
lcd_tx_dec3:
        push    bx
        push    cx
        push    dx

        xor     dx, dx
        mov     bx, 100
        div     bx              ; AX = centaines, DX = reste (0-99)
        mov     cl, al          ; CL = chiffre des centaines

        mov     ax, dx
        xor     dx, dx
        mov     bx, 10
        div     bx              ; AX = dizaines, DX = unites
        mov     ch, dl          ; CH = chiffre des unites
        mov     bh, al          ; BH = chiffre des dizaines

        mov     al, cl
        add     al, '0'
        call    lcd_data        ; centaines
        mov     al, bh
        add     al, '0'
        call    lcd_data        ; dizaines
        mov     al, ch
        add     al, '0'
        call    lcd_data        ; unites

        pop     dx
        pop     cx
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
