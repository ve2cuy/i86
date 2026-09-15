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

; ------------------------------------------------------------
; TEST_I2C_DUMP (decommenter la ligne %define ci-dessous pour
; activer): affiche en plus, sur le LCD I2C (PCF8574 0x27), les 16
; octets en hexadecimal de CHAQUE ligne du dump ROM (rom_dump/
; dump_line), 4 octets par ligne sur les 4 lignes du LCD 4x20 - en
; plus de ce qui s'affiche deja sur le LCD parallele et l'UART.
; Sert a mesurer/stresser le temps de reponse du LCD I2C: 257 mises
; a jour completes (une par ligne du dump), voir Directives.md.
; Desactive par defaut (aucun impact sur le comportement normal).
; %define TEST_I2C_DUMP
; ------------------------------------------------------------

; ------------------------------------------------------------
; TEST_PS2 (decommenter la ligne %define ci-dessous pour activer):
; diagnostic BAS NIVEAU du clavier PS/2 (PB0=CLOCK, PB1=DATA - voir
; lib/ps2.asm) - REMPLACE le menu interactif par une boucle infinie
; qui affiche sur l'UART le scan code BRUT (Set 2, sans traduction)
; de chaque trame recue. Utile pour verifier le cablage/protocole
; independamment de la couche de traduction clavier->ASCII
; (ps2_get_char) utilisee par le menu. Desactive par defaut (le
; menu, qui utilise deja le clavier via ps2_get_char, est le
; comportement normal - voir Directives.md).
; %define TEST_PS2
; ------------------------------------------------------------

%macro cls 0
        mov     si, CLS         ; efface l'ecran du terminal (ANSI)
        call    uart_tx_string
%endmacro

; --- ascii_or_dot: remplace AL par '.' s'il n'est pas imprimable
; --- (< 20h ou > 7Eh) - motif utilise par le dump ASCII UART
; --- (dump_line) ET le dump ASCII du LCD I2C (i2c_dump_hex_ascii8_line,
; --- TEST_I2C_DUMP), auparavant duplique dans les 2 routines. ---
%macro ascii_or_dot 0
        cmp     al, 20h
        jb      %%not_printable
        cmp     al, 7Eh
        ja      %%not_printable
        jmp     %%print_char
%%not_printable:
        mov     al, '.'
%%print_char:
%endmacro

; --- lcd_text: definit un texte LCD complete a une largeur fixe par
; --- des espaces, puis termine par 0 - motif utilise ~15 fois dans
; --- la section donnees ci-dessous (textes des 4 lignes du LCD 4x20).
; --- %1=etiquette, %2='texte' (chaine, eventuellement vide ''),
; --- %3=largeur visible (SANS compter le terminateur 0 ajoute apres). ---
%macro lcd_text 3
%1:             db      %2
                times   %3-($-%1) db ' '
                db      0
%endmacro

%include "include/hardware.inc"
%include "include/delay.inc"
%include "include/lcd_macros.inc"

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

%ifdef TEST_PS2
        ; --- Test PS/2 (TEST_PS2): boucle infinie qui affiche sur
        ; l'UART le scan code (Set 2, brut) de chaque trame recue du
        ; clavier, en polling pur (Port B du 8255, deja configure en
        ; ENTREE par init_8255/MASQUE_PIO ci-dessus). REMPLACE le
        ; reste du POST - voir lib/ps2.asm et la note pres de
        ; %define TEST_PS2 en haut du fichier. Ne retourne JAMAIS. ---
        mov     si, txt_ps2_attente
        call    uart_tx_string
.ps2_loop:
        call    ps2_read_byte    ; bloque - AL=scan code recu, CF=1 si trame invalide
        pushf                    ; CF doit survivre aux appels UART qui suivent
                                  ; (AL, lui, est deja preserve par uart_tx_string)
        mov     si, txt_ps2_recu
        call    uart_tx_string
        call    uart_tx_hex_byte ; affiche le scan code en hexa (AL toujours valide)
        popf
        jnc     .ps2_ok
        mov     si, txt_ps2_erreur
        call    uart_tx_string
        jmp     .ps2_next
.ps2_ok:
        mov     si, txt_crlf
        call    uart_tx_string
.ps2_next:
        jmp     .ps2_loop
%endif

        ; --- Test du LCD I2C (PCF8574 0x27, SDA=PA5, SCL=PA0): une
        ; seule fois au demarrage. PA0 est partagee avec D4 du LCD
        ; PARALLELE mais sans risque (voir lib/lcd_i2c.asm) - donc
        ; PAS besoin d'etre place avant lcd_init comme le serait un
        ; partage avec E; place ici simplement pour rester groupe
        ; avec le reste de l'init materielle ---
        call    i2c_lcd_init
        mov     si, i2c_txt_hello
        call    i2c_lcd_print   ; DDRAM deja en ligne 1 (Clear Display dans i2c_lcd_init)

        ; --- Ecran de demarrage: affiche une seule fois (pas a chaque
        ; cycle de .ici, contrairement au reste de l'affichage LCD),
        ; pendant 3 secondes, avant d'entrer dans la boucle principale ---
        call    lcd_init
        mov     si, lcd_txt_splash_l1
        lcd_show LCD_LINE1
        mov     si, lcd_txt_splash_l2
        lcd_show LCD_LINE2
        mov     si, lcd_txt_splash_l3
        lcd_show LCD_LINE3
        mov     si, lcd_txt_splash_l4
        lcd_show LCD_LINE4
        delay_ms (3*SECONDE)

        ; --- Bandeau d'identification: affiche une seule fois, avant
        ; d'entrer dans le menu (remplace l'ancienne boucle POST
        ; automatique .ici:/.temp: - voir Directives.md: le menu
        ; interactif, pilote par le clavier PS/2, est maintenant le
        ; comportement normal) ---
        cls                     ; efface l'ecran du terminal (ANSI)
        mov     si, txt_auteur
        call    uart_tx_string

; ============================================================
; Menu principal / menu Dump memory
; Chaque option est declenchee par l'utilisateur (clavier PS/2 -
; voir lib/ps2.asm, ps2_get_char) au lieu de s'enchainer
; automatiquement comme avant. Le menu courant est redessine
; (UART+LCD) apres chaque action, ou immediatement si la touche
; pressee n'est pas une des options listees.
; ============================================================
.main_menu:
        call    lcd_init                ; ecran propre pour le menu
        mov     si, txt_menu_main
        call    uart_tx_string
        mov     si, lcd_txt_menu_main_l1
        lcd_show LCD_LINE1
        mov     si, lcd_txt_menu_main_l2
        lcd_show LCD_LINE2
        mov     si, lcd_txt_menu_main_l3
        lcd_show LCD_LINE3
        mov     si, lcd_txt_menu_main_l4
        lcd_show LCD_LINE4

        call    ps2_get_char            ; bloque jusqu'a une touche reconnue

        cmp     al, '1'
        jne     .main_2
        call    lcd_init
        mov     si, lcd_txt_run_ram_l1
        lcd_show LCD_LINE1
        mov     si, lcd_txt_run_ram_l2
        lcd_show LCD_LINE2
        call    test_ram                ; teste toute la RAM (128K), rapporte via UART+LCD
        jmp     .main_menu
.main_2:
        cmp     al, '2'
        jne     .main_3
        jmp     .dump_menu
.main_3:
        cmp     al, '3'
        jne     .main_4
        call    lcd_init
        mov     si, lcd_txt_run_led_l1
        lcd_show LCD_LINE1
        mov     si, lcd_txt_run_led_l2
        lcd_show LCD_LINE2
        mov     si, lcd_txt_run_led_l4  ; texte fixe (ligne 3 = progression
        lcd_show LCD_LINE4              ; live, mise a jour par effet1)
        call    effet1                  ; animation Port C (chenillard)
        jmp     .main_menu
.main_4:
        cmp     al, '4'
        jne     .main_menu              ; touche non reconnue - redessine le menu
        call    edit_ram_action
        jmp     .main_menu

.dump_menu:
        call    lcd_init
        mov     si, txt_menu_dump
        call    uart_tx_string
        mov     si, lcd_txt_menu_dump_l1
        lcd_show LCD_LINE1
        mov     si, lcd_txt_menu_dump_l2
        lcd_show LCD_LINE2
        mov     si, lcd_txt_menu_dump_l3
        lcd_show LCD_LINE3
        mov     si, lcd_txt_menu_dump_l4
        lcd_show LCD_LINE4

        call    ps2_get_char

        cmp     al, '1'
        jne     .dump_2
        call    lcd_init
        mov     si, lcd_txt_run_romdump_l1
        lcd_show LCD_LINE1
        mov     si, lcd_txt_run_romdump_l2
        lcd_show LCD_LINE2
        call    rom_dump                ; dump des 4 premiers Ko de la ROM - voir plus bas
        jmp     .dump_menu
.dump_2:
        cmp     al, '2'
        jne     .dump_3
        call    lcd_init
        mov     si, lcd_txt_run_ramdump_l1
        lcd_show LCD_LINE1
        mov     si, lcd_txt_run_ramdump_l2
        lcd_show LCD_LINE2
        call    ram_dump_4k             ; dump des 4 premiers Ko de la RAM - voir plus bas
        jmp     .dump_menu
.dump_3:
        cmp     al, '3'
        jne     .dump_9
        call    edit_ram_action
        jmp     .dump_menu
.dump_9:
        cmp     al, '9'
        jne     .dump_menu              ; touche non reconnue - redessine le menu
        jmp     .main_menu

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
        ret                     ; retourne au menu (voir start:)

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
; ram_dump_4k
; Dump hexadecimal+ASCII des 4 premiers Ko de la RAM (segment
; 0000h, offsets 0000h-0FFFh) - reutilise dump_line TELLE QUELLE
; (256 lignes de 16 octets, memes formats UART/LCD[/LCD-I2C] que
; rom_dump), sans la ligne speciale des 16 derniers octets
; (specifique au vecteur de reset de la ROM, non pertinente ici).
;
; Note: la ligne 4 du LCD affiche "Ligne: NNN/257" (voir dump_line)
; - le "/257" reste celui du dump ROM (256+1 ligne speciale); ce
; dump RAM n'a que 256 lignes, le denominateur est donc legerement
; inexact pour ce cas - cosmetique seulement, pas corrige pour
; l'instant (voir Directives.md).
; ============================================================
RAM_DUMP_SIZE           equ     1000h           ; 4 Ko a dumper depuis le debut

ram_dump_4k:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        call    msg_ram_dump_banniere

        xor     ax, ax
        mov     es, ax          ; ES = 0000h (meme segment que le premier
                                 ; bloc teste par test_ram)
        xor     di, di
        mov     bx, 1
.line_loop:
        call    dump_line               ; affiche ES:DI (UART+LCD), avance DI de 16
        inc     bx
        cmp     di, RAM_DUMP_SIZE
        jb      .line_loop

        call    msg_dump_fin            ; reutilise le message existant ("Dump termine")

        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

EDIT_COLS               equ     6               ; octets par ligne de la grille d'edition
EDIT_ROWS               equ     4               ; lignes de la grille (= 4 lignes du LCD)

; ============================================================
; edit_ram_action
; Editeur de RAM interactif. Demande d'abord une adresse de depart
; ("Address: 0x____", 4 chiffres hexa, retour arriere pour corriger -
; voir ps2_read_hex_editable), puis affiche une grille de
; EDIT_ROWS x EDIT_COLS (4x6 = 24) octets consecutifs a partir de
; cette adresse, sur l'UART ET le LCD parallele (curseur MATERIEL du
; LCD actif et clignotant sur la case courante).
;
; Controles une fois dans la grille:
;   Fleches         - deplacent la case courante (limite a cette
;                     grille de 24 octets pour ce premier jalon -
;                     pas de defilement vers d'autres pages, voir
;                     Directives.md)
;   chiffre hexa     - compose une nouvelle valeur pour la case
;                     courante (1 ou 2 chiffres, retour arriere pour
;                     corriger - voir ps2_edit_byte_value)
;   Entree           - ecrit la valeur composee en RAM (si au moins
;                     un chiffre a ete tape - sinon ignoree)
;   Q ou q           - termine l'edition, retourne au menu
;
; Adresse "reelle" (segment 0000h, meme convention que rom_dump/
; dump_line) - AUCUNE verification de bornes: on peut ecrire
; n'importe ou dans les 64 Ko du segment 0000h, y compris hors de la
; zone testee par test_ram (voir son en-tete).
; ============================================================
edit_ram_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        call    lcd_init                ; ecran propre pour la saisie

        ; --- adresse de depart (avec correction) ---
        mov     si, txt_edit_address_prefix
        call    uart_tx_string
        mov     si, txt_edit_address_prefix
        lcd_show LCD_LINE1              ; curseur LCD reste juste apres "0x"
                                         ; (positionnement DDRAM auto-incremente)
        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 11     ; 11 = longueur de "Address: 0x"
        call    ps2_read_hex_editable   ; BX = adresse saisie (offset)

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte
        mov     si, txt_edit_help
        call    uart_tx_string

        ; --- memorise l'adresse de base et remet le curseur logique
        ; a (0,0) - vivent en RAM, voir hardware.inc ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     [es:di], bx
        mov     di, EDIT_ROW_OFF
        mov     byte [es:di], 0
        mov     di, EDIT_COL_OFF
        mov     byte [es:di], 0

.redraw:
        call    edit_ram_draw_grid

.wait_key:
        call    ps2_get_char

        cmp     al, 'q'
        je      .quit
        cmp     al, 'Q'
        je      .quit

        cmp     al, PS2_KEY_LEFT
        jne     .not_left
        call    edit_ram_move_left
        jmp     .redraw
.not_left:
        cmp     al, PS2_KEY_RIGHT
        jne     .not_right
        call    edit_ram_move_right
        jmp     .redraw
.not_right:
        cmp     al, PS2_KEY_UP
        jne     .not_up
        call    edit_ram_move_up
        jmp     .redraw
.not_up:
        cmp     al, PS2_KEY_DOWN
        jne     .not_down
        call    edit_ram_move_down
        jmp     .redraw
.not_down:
        ; --- toute autre touche: tente de composer une nouvelle
        ; valeur pour la case courante - ps2_edit_byte_value ignore
        ; lui-meme les touches non pertinentes (voir son en-tete) ---
        mov     dl, al                   ; DL = touche deja lue (sauvegardee -
                                          ; edit_ram_cell_ddram detruit AX)
        call    edit_ram_cell_ddram      ; AH = adresse DDRAM de la case courante
        mov     al, dl                   ; restaure AL = touche (AH inchange)
        call    ps2_edit_byte_value      ; AL(entree)=touche deja lue, CF=1 si rien tape
        jc      .redraw                  ; Entree sans saisie - rien a ecrire
        mov     dl, bl                   ; DL = valeur a ecrire (survit a l'appel)
        call    edit_ram_write_current
        jmp     .redraw

.quit:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_draw_grid
; (Re)affiche la grille EDIT_ROWS x EDIT_COLS a partir de
; EDIT_BASE_OFF (VAR_SEG), sur l'UART et le LCD parallele - puis
; positionne le curseur materiel du LCD (actif, clignotant) sur la
; cellule EDIT_ROW_OFF/EDIT_COL_OFF.
; ============================================================
edit_ram_draw_grid:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     bx, [es:di]      ; BX = adresse de base (offset RAM, segment 0000h)

        call    lcd_init         ; ecran propre a chaque redessin (simple/robuste)

        xor     ax, ax
        mov     es, ax           ; ES = 0000h (segment RAM edite)
        mov     di, bx           ; DI = adresse courante, avance octet par octet

        mov     dh, 0            ; DH = ligne courante (0-3)
.row_loop:
        cmp     dh, 0
        jne     .row_not0
        lcd_goto LCD_LINE1
        jmp     .row_go
.row_not0:
        cmp     dh, 1
        jne     .row_not1
        lcd_goto LCD_LINE2
        jmp     .row_go
.row_not1:
        cmp     dh, 2
        jne     .row_not2
        lcd_goto LCD_LINE3
        jmp     .row_go
.row_not2:
        lcd_goto LCD_LINE4
.row_go:
        ; --- UART: adresse reelle de debut de cette ligne ---
        mov     ax, di
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte

        mov     dl, 0            ; DL = colonne courante (0-5)
.col_loop:
        mov     al, [es:di]
        mov     ah, al           ; AH = copie de l'octet - survit a lcd_tx_hex_byte
                                  ; (qui detruit AL, mais jamais AH - voir def_tx_hex_*)
        call    lcd_tx_hex_byte
        mov     al, ah
        call    uart_tx_hex_byte
        mov     al, ' '
        call    lcd_data
        mov     al, ' '
        call    uart_tx_byte
        inc     di
        inc     dl
        cmp     dl, EDIT_COLS
        jb      .col_loop

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte

        inc     dh
        cmp     dh, EDIT_ROWS
        jb      .row_loop

        call    edit_ram_place_cursor

        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_cell_ddram
; Calcule l'adresse DDRAM (SANS le bit de commande) de la case
; courante (EDIT_ROW_OFF/EDIT_COL_OFF) - "XX " = 3 caracteres par
; cellule sur le LCD.
; Sortie: AH = adresse DDRAM (0-127).
; ============================================================
edit_ram_cell_ddram:
        push    bx
        push    cx
        push    es
        push    di

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_ROW_OFF
        mov     bh, [es:di]      ; BH = ligne (0-3)
        mov     di, EDIT_COL_OFF
        mov     bl, [es:di]      ; BL = colonne (0-5)

        mov     al, bl
        mov     cl, 3
        mul     cl               ; AX = colonne*3
        mov     cl, al           ; CL = decalage colonne (0,3,...,15)

        cmp     bh, 0
        je      .r0
        cmp     bh, 1
        je      .r1
        cmp     bh, 2
        je      .r2
        mov     al, LCD_LINE4 & 07Fh
        jmp     .go
.r0:    mov     al, LCD_LINE1 & 07Fh
        jmp     .go
.r1:    mov     al, LCD_LINE2 & 07Fh
        jmp     .go
.r2:    mov     al, LCD_LINE3 & 07Fh
.go:
        add     al, cl
        mov     ah, al           ; AH = adresse DDRAM (sortie)

        pop     di
        pop     es
        pop     cx
        pop     bx
        ret

; ============================================================
; edit_ram_place_cursor
; Positionne le curseur materiel du LCD (active, clignotant) sur la
; cellule courante (voir edit_ram_cell_ddram).
; ============================================================
edit_ram_place_cursor:
        push    ax
        call    edit_ram_cell_ddram
        mov     al, ah
        or      al, 80h
        call    lcd_command
        mov     al, 00001111b    ; Display ON, curseur ON, clignotement ON
        call    lcd_command
        pop     ax
        ret

; ============================================================
; edit_ram_write_current
; Ecrit DL en RAM (segment 0000h) a l'adresse EDIT_BASE_OFF +
; EDIT_ROW_OFF*EDIT_COLS + EDIT_COL_OFF.
; Entree: DL = valeur a ecrire.
; ============================================================
edit_ram_write_current:
        push    ax
        push    bx
        push    cx
        push    di
        push    es

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     bx, [es:di]      ; BX = adresse de base
        mov     di, EDIT_ROW_OFF
        mov     al, [es:di]      ; AL = ligne (0-3)
        mov     cl, EDIT_COLS
        mul     cl               ; AX = ligne*EDIT_COLS
        add     bx, ax           ; BX += ligne*EDIT_COLS
        mov     di, EDIT_COL_OFF
        mov     al, [es:di]      ; AL = colonne (0-5)
        xor     ah, ah
        add     bx, ax           ; BX += colonne -> BX = adresse RAM cible

        xor     ax, ax
        mov     es, ax           ; ES = 0000h
        mov     di, bx
        mov     [es:di], dl

        pop     es
        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_move_left / _right / _up / _down
; Deplace le curseur logique (EDIT_ROW_OFF/EDIT_COL_OFF, VAR_SEG)
; dans la grille - fixe aux bords (pas de defilement au-dela de la
; grille initialement affichee pour ce premier jalon - voir
; Directives.md).
; ============================================================
edit_ram_move_left:
        push    ax
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_COL_OFF
        cmp     byte [es:di], 0
        je      .done
        dec     byte [es:di]
.done:
        pop     di
        pop     es
        pop     ax
        ret

edit_ram_move_right:
        push    ax
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_COL_OFF
        cmp     byte [es:di], EDIT_COLS-1
        jae     .done
        inc     byte [es:di]
.done:
        pop     di
        pop     es
        pop     ax
        ret

edit_ram_move_up:
        push    ax
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_ROW_OFF
        cmp     byte [es:di], 0
        je      .done
        dec     byte [es:di]
.done:
        pop     di
        pop     es
        pop     ax
        ret

edit_ram_move_down:
        push    ax
        push    es
        push    di
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_ROW_OFF
        cmp     byte [es:di], EDIT_ROWS-1
        jae     .done
        inc     byte [es:di]
.done:
        pop     di
        pop     es
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
        lcd_goto LCD_LINE2
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
        lcd_goto LCD_LINE3
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
        lcd_goto LCD_LINE4
        mov     si, lcd_txt_ligne_prefix
        call    lcd_print
        mov     ax, bx
        call    lcd_tx_dec3
        mov     si, lcd_txt_ligne_suffix
        call    lcd_print

%ifdef TEST_I2C_DUMP
        ; --- LCD I2C (TEST_I2C_DUMP): dump complet des 16 octets en
        ; hexadecimal, 4 par ligne sur les 4 lignes du LCD 4x20 - voir
        ; la note pres de %define TEST_I2C_DUMP en haut du fichier.
        ; ASCII (8 caracteres/groupe de 8 octets) affiche seulement
        ; sur les lignes 1 et 3 - voir i2c_dump_hex_ascii8_line ---
        push    di
        i2c_lcd_goto LCD_LINE1
        call    i2c_dump_hex_ascii8_line       ; hexa bytes[0:4] + ascii bytes[0:8]
        i2c_lcd_goto LCD_LINE2
        call    i2c_dump_hex_only_line         ; hexa bytes[4:8] seulement
        i2c_lcd_goto LCD_LINE3
        call    i2c_dump_hex_ascii8_line       ; hexa bytes[8:12] + ascii bytes[8:16]
        i2c_lcd_goto LCD_LINE4
        call    i2c_dump_hex_only_line         ; hexa bytes[12:16] seulement
        pop     di
%endif

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
        ascii_or_dot
        call    uart_tx_byte
        inc     di
        loop    .ascii_loop

        mov     si, txt_crlf
        call    uart_tx_string
        ret

%ifdef TEST_I2C_DUMP
; --- i2c_dump_hex4: affiche les 4 octets ES:DI en hexadecimal
; --- (separes par un espace) sur le LCD I2C, avance DI de 4 -
; --- factorise entre i2c_dump_hex_only_line et
; --- i2c_dump_hex_ascii8_line ci-dessous, qui partageaient ce code. ---
%macro i2c_dump_hex4 0
        mov     cx, 4
%%loop:
        mov     al, [es:di]
        call    i2c_lcd_tx_hex_byte
        cmp     cx, 1
        je      %%last
        mov     al, ' '
        call    i2c_lcd_data
%%last:
        inc     di
        loop    %%loop
%endmacro

; ============================================================
; i2c_dump_hex_only_line (TEST_I2C_DUMP uniquement)
; Affiche 4 octets en hexadecimal (separes par un espace), SANS
; ASCII - utilisee pour les lignes 2 et 4 (voir dump_line;
; i2c_dump_hex_ascii8_line, pour les lignes 1 et 3, affiche deja
; l'ASCII de ces 4 octets en plus des siens). "XX XX XX XX" = 11
; caracteres, dans les 20 colonnes disponibles.
; Entree:  ES:DI = 4 octets a afficher.
; Sortie:  DI avance de 4.
; ============================================================
i2c_dump_hex_only_line:
        push    ax
        push    cx
        i2c_dump_hex4
        pop     cx
        pop     ax
        ret

; ============================================================
; i2c_dump_hex_ascii8_line (TEST_I2C_DUMP uniquement)
; Affiche 4 octets en hexadecimal (separes par un espace), un espace,
; puis les 8 caracteres ASCII correspondant a CE groupe de 4 octets
; ET AU SUIVANT (ou '.' si non imprimable, meme regle que le dump
; UART - voir plus bas) - utilisee pour les lignes 1 et 3 (voir
; dump_line), le groupe suivant (lignes 2/4) n'affichant alors plus
; d'ASCII du tout (voir i2c_dump_hex_only_line). "XX XX XX XX ASCIIII"
; = 11+1+8 = 20 caracteres EXACTEMENT (pleine largeur).
; Entree:  ES:DI = 4 octets a afficher en hexa - le debut de ce
;          groupe ET du suivant (8 octets au total pour l'ASCII),
;          donc AVANT que le groupe suivant soit lu par
;          i2c_dump_hex_only_line.
; Sortie:  DI avance de 4 (seul le groupe hexa affiche par CET appel
;          est "consomme" du point de vue de DI - le suivant reste a
;          lire par le prochain appel, comme d'habitude).
; ============================================================
i2c_dump_hex_ascii8_line:
        push    ax
        push    cx
        push    si
        mov     si, di          ; SI = debut de CE groupe de 4 (pour les 8
                                 ; octets ASCII: ce groupe + le suivant) -
                                 ; DI, lui, doit finir avance de 4 seulement
                                 ; (contrat de sortie, utilise par dump_line)
        i2c_dump_hex4

        mov     al, ' '                 ; separateur entre hexa et ascii
        call    i2c_lcd_data

        mov     cx, 8
.ascii_loop:
        mov     al, [es:si]
        ascii_or_dot
        call    i2c_lcd_data
        inc     si
        loop    .ascii_loop

        pop     si
        pop     cx
        pop     ax
        ret
%endif

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
        lcd_goto LCD_LINE2

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
        lcd_goto LCD_LINE3
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

        lcd_goto LCD_LINE4
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
; msg_dump_banniere / msg_dump_fin / msg_ram_dump_banniere
; ============================================================
msg_dump_banniere:
        mov     si, txt_dump_banniere
        call    uart_tx_string
        ret

msg_dump_fin:
        mov     si, txt_dump_fin
        call    uart_tx_string
        ret

msg_ram_dump_banniere:
        mov     si, txt_ram_dump_banniere
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
        lcd_goto LCD_LINE3
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
%include "lib/lcd_i2c.asm"
%include "lib/ps2.asm"

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
%ifdef TEST_PS2
txt_ps2_attente:        db      27,'[36m','=== Test PS/2 (TEST_PS2): en attente de frappes clavier (Set 2, brut) ===',27,'[0m',13,10,0
txt_ps2_recu:           db      'Scan code recu: 0x',0
txt_ps2_erreur:         db      ' <<< ERREUR (parite ou bit stop invalide)',13,10,0
%endif

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

txt_ram_dump_banniere:  db      27,'[34m','=== Dump RAM - 4 premiers Ko (0000:0000-0000:0FF0) ===',27,'[0m',13,10,13,10,0

txt_auteur:             db      '8088 sur breadboard version 2026',13,10
                        db      'Par Alain Boudreault, aka VE2CUY',13,10
                        db      '--------------------------------',13,10,13,10,0

; ---- menu principal / menu Dump memory (voir start:) - textes UART,
; ---- affiches en plus des lignes LCD dediees ci-dessous ----
txt_menu_main:          db      27,'[36m','--- Menu principal ---',27,'[0m',13,10
                        db      '1) Test RAM',13,10
                        db      '2) Dump memory',13,10
                        db      '3) LED Show on PC',13,10
                        db      '4) Edit RAM',13,10,13,10,0

txt_menu_dump:          db      27,'[36m','--- Menu Dump memory ---',27,'[0m',13,10
                        db      '1) Dump ROM',13,10
                        db      '2) Dump first 4k RAM',13,10
                        db      '3) Edit RAM',13,10
                        db      '9) Home menu',13,10,13,10,0

; ---- invite "Edit RAM" (voir edit_ram_action) ----
txt_edit_address_prefix: db     'Address: 0x', 0
txt_edit_help:           db     27,'[36m','Fleches: deplacer | chiffre hexa: editer | Entree: enregistrer | Q: quitter',27,'[0m',13,10,13,10,0

; ---- texte du LCD I2C (PCF8574 0x27) - pas de padding, pas de
; ---- largeur fixe imposee comme sur le LCD parallele ----
i2c_txt_hello:          db      'Hello World', 0

; ---- textes LCD (20 caracteres, complete automatiquement par des
; ---- espaces via "times" - afficheur 4x20) ----

; ---- ecran de demarrage (3 secondes, une seule fois - voir start:) ----
lcd_text lcd_txt_splash_l1, 'Breadboard 8088', 20
lcd_text lcd_txt_splash_l2, 'Version 1.0', 20
lcd_txt_splash_l3:      times   20 db '-'       ; remplissage '-' (pas ' ') - hors macro
                        db      0
lcd_text lcd_txt_splash_l4, '(c) VE2CUY 2026', 20

; ---- menu principal (voir start:) - 1 ligne LCD par option, meme
; ---- texte que le menu UART (txt_menu_main) ----
lcd_text lcd_txt_menu_main_l1, '1) Test RAM', 20
lcd_text lcd_txt_menu_main_l2, '2) Dump memory', 20
lcd_text lcd_txt_menu_main_l3, '3) LED Show on PC', 20
lcd_text lcd_txt_menu_main_l4, '4) Edit RAM', 20

; ---- menu Dump memory (voir start:) ----
lcd_text lcd_txt_menu_dump_l1, '1) Dump ROM', 20
lcd_text lcd_txt_menu_dump_l2, '2) Dump first 4k RAM', 20
lcd_text lcd_txt_menu_dump_l3, '3) Edit RAM', 20
lcd_text lcd_txt_menu_dump_l4, '9) Home menu', 20

; ---- bandeau ligne1/ligne2 affiche avant chaque action lancee depuis
; ---- un menu (lignes 3/4 sont mises a jour en direct par l'action
; ---- elle-meme - voir start:) ----
lcd_text lcd_txt_run_ram_l1, 'Test RAM 128K', 20
lcd_text lcd_txt_run_ram_l2, 'En cours...', 20

lcd_text lcd_txt_run_led_l1, 'Test 8255', 20
lcd_text lcd_txt_run_led_l2, 'Chenillard Port C', 20
lcd_text lcd_txt_run_led_l4, 'VE2CUY 2026', 20

lcd_text lcd_txt_run_romdump_l1, 'Dump ROM', 20
lcd_text lcd_txt_run_romdump_l2, 'Dump 4K+16 octets', 20

lcd_text lcd_txt_run_ramdump_l1, 'Dump RAM 4K', 20
lcd_text lcd_txt_run_ramdump_l2, 'En cours...', 20

; ---- complement de 11 espaces utilise par dump_line, apres les 9
; ---- caracteres d'adresse "SSSS:OOOO" (9+11=20) ----
lcd_text lcd_txt_dump_pad, '', 11

; ---- ligne 3 de l'etape 2 (msg_bloc_progression): etat en toutes
; ---- lettres, 20 caracteres ----
lcd_text lcd_txt_etat_ok, 'Etat: OK', 20
lcd_text lcd_txt_etat_defaut, 'Etat: DEFAUT', 20

; ---- ligne 4 de l'etape 2: "Bloc:" + dec3 + "/127 Def:" + dec3 =
; ---- 5+3+9+3 = 20 caracteres EXACTEMENT (pas de padding requis) ----
lcd_txt_bloc_prefix:    db      'Bloc:', 0
lcd_txt_bloc_mid:       db      '/127 Def:', 0

; ---- ligne 3 de l'etape 1 (effet1): "Passe: " + dec3 + "/16" +
; ---- 7 espaces = 7+3+10 = 20 caracteres ----
lcd_txt_passe_prefix:   db      'Passe: ', 0
lcd_text lcd_txt_passe_suffix, '/16', 10

; ---- ligne 4 de l'etape 3 (dump_line): "Ligne: " + dec3 + "/257" +
; ---- 6 espaces = 7+3+10 = 20 caracteres ----
lcd_txt_ligne_prefix:   db      'Ligne: ', 0
lcd_text lcd_txt_ligne_suffix, '/257', 10

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
