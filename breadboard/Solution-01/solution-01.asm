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
; octets en hexadecimal de CHAQUE ligne d'un dump memoire
; (dump_memory_action/dump_line), 4 octets par ligne sur les 4 lignes
; du LCD 4x20 - en plus de ce qui s'affiche deja sur le LCD parallele
; et l'UART. Sert a mesurer/stresser le temps de reponse du LCD I2C
; (une mise a jour complete par ligne du dump), voir Directives.md.
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

        call    setup_bios_interrupts  ; peuple l'IVT pour INT 10h/16h
                                         ; ("esprit BIOS" - voir plus bas)

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

        ; --- LCD I2C (PCF8574 0x27, SDA=PA5, SCL=PA0): affiche la
        ; version de l'application et les parametres de la connexion
        ; UART, une seule fois au demarrage. PA0 est partagee avec D4
        ; du LCD PARALLELE mais sans risque (voir lib/lcd_i2c.asm) -
        ; donc PAS besoin d'etre place avant lcd_init comme le serait
        ; un partage avec E; place ici simplement pour rester groupe
        ; avec le reste de l'init materielle ---
        call    i2c_lcd_init
        mov     si, lcd_txt_splash_l1          ; "Breadboard 8088"
        i2c_lcd_show LCD_LINE1
        mov     si, lcd_txt_splash_l2          ; "Version 1.0"
        i2c_lcd_show LCD_LINE2
        mov     si, i2c_txt_uart_params        ; "UART: 9600 8N1"
        i2c_lcd_show LCD_LINE3
        mov     si, lcd_txt_splash_l4          ; "(c) VE2CUY 2026"
        i2c_lcd_show LCD_LINE4

        ; --- Ecran de demarrage: affiche une seule fois (pas a chaque
        ; cycle de .ici, contrairement au reste de l'affichage LCD),
        ; pendant 1 seconde, avant d'entrer dans la boucle principale ---
        call    lcd_init
        mov     si, lcd_txt_splash_l1
        lcd_show LCD_LINE1
        mov     si, lcd_txt_splash_l2
        lcd_show LCD_LINE2
        mov     si, lcd_txt_splash_l3
        lcd_show LCD_LINE3
        mov     si, lcd_txt_splash_l4
        lcd_show LCD_LINE4
        delay_ms (1*SECONDE)

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
        mov     si, lcd_txt_menu_dump_l4
        lcd_show LCD_LINE4

        call    ps2_get_char

        cmp     al, '1'
        jne     .dump_2
        call    dump_memory_action      ; demande adresses depart/fin, dump - voir plus bas
        jmp     .dump_menu
.dump_2:
        cmp     al, '2'
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
; mem_calc_physical
; Calcule l'adresse physique 20 bits (SEGMENT*16 + OFFSET) d'un
; couple segment:offset, en 32 bits (DX:AX) - un registre complet
; est utilise (plutot que 20 bits precis) pour que la comparaison et
; la soustraction faites par dump_memory_action restent simples,
; meme si DX vaut toujours 0 en pratique sur ce materiel (bus
; d'adresse 8088 a 20 lignes seulement).
;
; Entree:  AX = segment, BX = offset
; Sortie:  DX:AX = adresse physique (DX = poids fort, AX = poids
;          faible)
; Detruit: CX
; ============================================================
mem_calc_physical:
        xor     dx, dx
        mov     cx, 4
.shl4:
        shl     ax, 1
        rcl     dx, 1
        loop    .shl4
        add     ax, bx
        adc     dx, 0
        ret

; ============================================================
; dump_memory_action
; Consolide les anciennes options "Dump ROM" et "Dump first 4k RAM"
; du menu Dump memory sous une seule action: demande une adresse de
; DEPART puis une adresse de FIN, chacune saisie au clavier sous la
; forme SEGMENT:OFFSET (4+4 chiffres hexa, retour arriere pour
; corriger - voir ps2_read_hex_editable), puis affiche en
; hexadecimal+ASCII (UART) et hexadecimal condense (LCD[+LCD-I2C si
; TEST_I2C_DUMP]) tous les octets de cette plage physique, 16 octets
; par ligne, via dump_line (inchangee).
;
; Fonctionne indifferemment pour la ROM (ex: C000:0000 a F000:FFFF
; pour toute la ROM, 256 Ko), la RAM (ex: 0000:0000 a 1000:FFFF pour
; toute la RAM, 128 Ko) ou n'importe quelle plage intermediaire -
; plus besoin de deux procedures separees.
;
; La plage peut traverser une frontiere de segment (ex: 0000:FFF0 a
; 1000:0010): l'offset (DI) est avance de 16 a chaque ligne comme
; avant; en cas de debordement (DI redevient <= sa valeur d'avant
; l'ajout), le segment (ES) est avance de 1000h pour rester a la
; bonne adresse physique (1 paragraphe = 16 octets = 1000h en
; unites de segment).
;
; Validation: si l'adresse de fin (physique) est STRICTEMENT
; INFERIEURE a celle de depart, la plage est invalide - un message
; d'erreur est affiche (UART, en rouge) et la fonction retourne sans
; rien dumper.
;
; Interruption au clavier: la touche Echap, verifiee de facon NON
; BLOQUANTE avant chaque ligne (CLOCK/PB0 est HAUT au repos - un
; "IN AL,PORTB" suffit a detecter qu'une trame est en cours, sans
; ralentir le dump quand aucune touche n'est pressee), interrompt le
; dump et retourne au menu. Best-effort: une touche pressee et
; relachee tres brievement PENDANT l'impression d'une ligne (qui peut
; prendre plusieurs dizaines de ms sur l'UART logiciel a 9600 bauds)
; peut echapper a la verification suivante si elle est deja terminee
; a ce moment-la - appuyer de nouveau sur Echap si le dump ne s'arrete
; pas immediatement.
;
; Limitation connue (affichage seulement): la ligne 4 du LCD affiche
; desormais "Ligne: NNN" (numero de la ligne courante, SANS total -
; contrairement a l'ancien "NNN/257" fixe, devenu incorrect des que
; la taille de la plage varie). lcd_tx_dec3 n'affiche que 3 chiffres
; (0-999): au-dela de 999 lignes (15984 octets) ce numero redevient
; incorrect (cosmetique seulement, voir Directives.md) - le dump
; UART, lui, reste toujours exact quelle que soit la taille de la
; plage.
; ============================================================
dump_memory_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        call    lcd_init

        ; --- adresse de depart (ligne 1 du LCD) ---
        mov     si, txt_dump_start_prefix       ; "Start: 0x"
        call    uart_tx_string
        mov     si, txt_dump_start_prefix
        lcd_show LCD_LINE1
        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 9      ; 9 = long. de "Start: 0x"
        call    ps2_read_hex_editable           ; BX = segment de depart
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_SEG_OFF
        mov     [es:di], bx

        mov     si, txt_dump_seg_off_sep        ; ":0x"
        call    uart_tx_string
        mov     si, txt_dump_seg_off_sep
        call    lcd_print
        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 16     ; 16 = long. de "Start: 0xSSSS:0x"
        call    ps2_read_hex_editable           ; BX = offset de depart
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_OFF_OFF
        mov     [es:di], bx

        ; --- adresse de fin (ligne 2 du LCD) ---
        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte
        mov     si, txt_dump_end_prefix         ; "End:   0x"
        call    uart_tx_string
        mov     si, txt_dump_end_prefix
        lcd_show LCD_LINE2
        mov     cl, 4
        mov     ah, (LCD_LINE2 & 07Fh) + 9      ; 9 = long. de "End:   0x"
        call    ps2_read_hex_editable           ; BX = segment de fin
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_SEG_OFF
        mov     [es:di], bx

        mov     si, txt_dump_seg_off_sep
        call    uart_tx_string
        mov     si, txt_dump_seg_off_sep
        call    lcd_print
        mov     cl, 4
        mov     ah, (LCD_LINE2 & 07Fh) + 16     ; 16 = long. de "End:   0xSSSS:0x"
        call    ps2_read_hex_editable           ; BX = offset de fin
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_OFF_OFF
        mov     [es:di], bx

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte

        ; --- bandeau UART: rappelle les deux adresses saisies ---
        mov     si, txt_dump_banniere1
        call    uart_tx_string
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_SEG_OFF
        mov     ax, [es:di]
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_OFF_OFF
        mov     ax, [es:di]
        call    uart_tx_hex_word
        mov     si, txt_dump_banniere2
        call    uart_tx_string
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_SEG_OFF
        mov     ax, [es:di]
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_OFF_OFF
        mov     ax, [es:di]
        call    uart_tx_hex_word
        mov     si, txt_dump_banniere3
        call    uart_tx_string

        ; --- calcule les adresses physiques (32 bits: DX:AX) ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_SEG_OFF
        mov     ax, [es:di]                     ; AX = segment de depart
        mov     di, DUMP_START_OFF_OFF
        mov     bx, [es:di]                     ; BX = offset de depart
        call    mem_calc_physical               ; DX:AX = adresse physique de depart
        push    dx
        push    ax                              ; empile start_phys (hi puis lo)

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_END_SEG_OFF
        mov     ax, [es:di]                     ; AX = segment de fin
        mov     di, DUMP_END_OFF_OFF
        mov     bx, [es:di]                     ; BX = offset de fin
        call    mem_calc_physical               ; DX:AX = adresse physique de fin

        pop     cx                              ; CX = start_phys (poids faible)
        pop     bp                              ; BP = start_phys (poids fort)

        cmp     dx, bp
        jb      .invalid_range
        ja      .range_ok
        cmp     ax, cx
        jb      .invalid_range
.range_ok:
        ; --- diff = end_phys - start_phys (32 bits), puis
        ; --- total_lines = diff/16 + 1 (division par 16 = 4 decalages
        ; --- a droite du couple DX:AX) ---
        sub     ax, cx
        sbb     dx, bp
        mov     cx, 4
.shr32:
        shr     dx, 1
        rcr     ax, 1
        loop    .shr32
        inc     ax                              ; AX = total_lines (DX ignore -
                                                  ; toujours 0 pour une plage valide
                                                  ; sur ce materiel, voir en-tete)

        ; --- compteur de lignes restantes: memorise en RAM (VAR_SEG),
        ; --- PAS dans CX - dump_line detruit CX (voir son en-tete),
        ; --- un simple "loop" n'y survivrait pas d'une iteration a
        ; --- l'autre ---
        mov     bx, VAR_SEG
        mov     es, bx
        mov     di, DUMP_LINES_LEFT_OFF
        mov     [es:di], ax

        ; --- ES:DI = adresse de depart (telle que saisie - pas
        ; --- renormalisee - pour que la premiere ligne affichee
        ; --- corresponde exactement a ce qui a ete tape) ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, DUMP_START_SEG_OFF
        mov     ax, [es:di]                     ; AX = segment de depart
        mov     di, DUMP_START_OFF_OFF
        mov     bx, [es:di]                     ; BX = offset de depart
        mov     es, ax                          ; ES = segment de depart (bascule enfin
                                                  ; sur le segment de la plage a dumper)
        mov     di, bx                          ; DI = offset de depart

        mov     bx, 1                            ; BX = numero de ligne courant (1-based,
                                                  ; pour "Ligne: NNN" sur le LCD)
.line_loop:
        ; --- interruption au clavier (Echap): verification NON
        ; BLOQUANTE avant chaque ligne - CLOCK (PB0) est HAUT au repos
        ; (voir lib/ps2.asm), donc un simple "IN AL,PORTB" suffit a
        ; detecter qu'une trame est en cours SANS ralentir le dump
        ; quand aucune touche n'est pressee (cas normal). Si une trame
        ; est en cours, ps2_get_char la lit entierement (bloquant,
        ; bref: <2ms) et se resynchronise lui-meme au besoin. ---
        in      al, PORTB
        test    al, PS2_CLOCK
        jnz     .no_key                         ; CLOCK haut (repos) - rien a lire
        push    bx                              ; ps2_get_char detruit BX (numero de
        call    ps2_get_char                    ; ligne courant, doit survivre) - voir
        pop     bx                              ; son en-tete
        cmp     al, 27                          ; Echap ?
        je      .interrupted
.no_key:
        push    di
        call    dump_line                       ; affiche ES:DI (UART+LCD), avance DI de 16
        pop     dx                               ; DX = DI D'AVANT l'appel
        cmp     di, dx
        ja      .no_wrap                         ; DI a augmente normalement
        mov     ax, es                           ; debordement 16 bits: avance le segment
        add     ax, 1000h                        ; d'un paragraphe (16 octets = 1000h en
        mov     es, ax                           ; unites de segment)
.no_wrap:
        inc     bx

        ; --- decompte du nombre de lignes restantes (VAR_SEG) - ES
        ; --- (segment du dump en cours) est sauvegarde/restaure
        ; --- autour de ce court aller-retour ---
        push    es
        mov     ax, VAR_SEG
        mov     es, ax
        mov     si, DUMP_LINES_LEFT_OFF
        dec     word [es:si]
        mov     ax, [es:si]
        pop     es
        cmp     ax, 0
        jne     .line_loop

        call    msg_dump_fin
        jmp     .done

.interrupted:
        mov     si, txt_dump_interrupted
        call    uart_tx_string
        jmp     .done

.invalid_range:
        mov     si, txt_dump_invalid_range
        call    uart_tx_string

.done:
        pop     es
        pop     bp
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
; Adresse "reelle" (segment 0000h, meme convention que dump_line) -
; AUCUNE verification de bornes: on peut ecrire
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
        call    edit_ram_advance         ; passe a la case suivante (ordre de lecture)
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
; edit_ram_advance
; Deplace le curseur logique a la case SUIVANTE en ordre de lecture
; (gauche a droite, puis ligne suivante) - appelee apres Entree pour
; passer automatiquement a l'octet suivant, sans avoir a re-appuyer
; sur une fleche. Fixe a la derniere case de la grille (pas de retour
; au debut - meme limite que les fleches, voir Directives.md).
; ============================================================
edit_ram_advance:
        push    ax
        push    es
        push    di

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_COL_OFF
        cmp     byte [es:di], EDIT_COLS-1
        jb      .same_row
        ; --- fin de ligne: colonne -> 0, tente de passer a la ligne
        ; suivante (fixe si deja sur la derniere - pas de defilement) ---
        mov     byte [es:di], 0
        mov     di, EDIT_ROW_OFF
        cmp     byte [es:di], EDIT_ROWS-1
        jae     .done
        inc     byte [es:di]
        jmp     .done
.same_row:
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
;     ligne 4 = "Ligne: NNN" (numero de cette ligne, sans total - voir
;               dump_memory_action)
;
; Entree:  ES:DI = adresse de depart de la ligne (16 octets)
;          BX = numero de cette ligne (1-based, prepare par
;               dump_memory_action)
; Sortie:  DI avance de 16 (adresse de la ligne suivante). BX et ES
;          inchanges - IMPORTANT: CX (et AX, DX, SI) sont en revanche
;          DETRUITS (loops internes de cette procedure) - tout
;          appelant qui boucle sur plusieurs lignes doit garder son
;          propre compteur ailleurs que dans CX (voir
;          dump_memory_action, qui le stocke en RAM plutot que
;          d'utiliser une instruction "loop").
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

        ; --- Ligne 4 du LCD: numero de cette ligne (BX prepare par
        ; dump_memory_action) ---
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
; msg_dump_fin
; ============================================================
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

; ============================================================
; setup_bios_interrupts
; Peuple l'IVT (segment 0000h, RAM) pour INT 10h (affichage) et
; INT 16h (clavier) - chaque entree est un pointeur FAR (offset puis
; segment, 4 octets, a l'adresse INT_NUM*4) vers int10h_handler/
; int16h_handler ci-dessous. Initialise aussi le curseur logique
; "esprit BIOS" (BIOS_CURSOR_ROW_OFF/COL_OFF) a (0,0). Appelee une
; seule fois au demarrage (voir start:), avant toute utilisation de
; INT 10h/16h.
; ============================================================
setup_bios_interrupts:
        push    ax
        push    es

        xor     ax, ax
        mov     es, ax                          ; ES = 0000h (segment de l'IVT)
        mov     word [es:10h*4], int10h_handler
        mov     word [es:10h*4+2], cs
        mov     word [es:16h*4], int16h_handler
        mov     word [es:16h*4+2], cs

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_CURSOR_ROW_OFF
        mov     byte [es:di], 0
        mov     di, BIOS_CURSOR_COL_OFF
        mov     byte [es:di], 0

        pop     es
        pop     ax
        ret

; ============================================================
; bios_cursor_ddram
; Calcule l'adresse DDRAM (SANS le bit de commande) correspondant a
; DH=ligne (0-3) / DL=colonne (0-19) - meme convention 4x20 que
; LCD_LINE1..4 (include/lcd_macros.inc), utilisee par int10h_handler.
; Aucune verification de bornes (meme choix que edit_ram_action).
; Entree:  DH = ligne, DL = colonne
; Sortie:  AH = adresse DDRAM (0-127)
; Detruit: rien d'autre que AH
; ============================================================
bios_cursor_ddram:
        push    bx
        cmp     dh, 0
        je      .r0
        cmp     dh, 1
        je      .r1
        cmp     dh, 2
        je      .r2
        mov     bl, LCD_LINE4 & 07Fh
        jmp     .add_col
.r0:    mov     bl, LCD_LINE1 & 07Fh
        jmp     .add_col
.r1:    mov     bl, LCD_LINE2 & 07Fh
        jmp     .add_col
.r2:    mov     bl, LCD_LINE3 & 07Fh
.add_col:
        add     bl, dl
        mov     ah, bl
        pop     bx
        ret

; ============================================================
; int10h_handler
; Gestionnaire de INT 10h (affichage), sous-ensemble "esprit BIOS"
; adapte a ce materiel (2 LCD HD44780 4x20 - pas de memoire video ni
; de VGA):
;
;   AH=02h - Positionne le curseur LOGIQUE (persiste en RAM, voir
;            BIOS_CURSOR_ROW_OFF/COL_OFF): DH=ligne (0-3), DL=colonne
;            (0-19). Aucune verification de bornes. Ce curseur est
;            PARTAGE entre les 2 afficheurs (le HD44780 n'a pas de
;            notion de "curseur commun" a 2 peripheriques distincts -
;            voir AH=09h) - repositionner avant d'ecrire sur l'autre
;            afficheur si necessaire.
;
;   AH=09h - Ecrit AL au curseur logique courant, CX fois de suite
;            (remplit CX cellules CONSECUTIVES a partir de cette
;            position - meme convention que le vrai BIOS IBM PC, PAS
;            "le meme caractere CX fois au meme endroit"). Le
;            debordement d'une ligne de 20 suit l'auto-increment
;            materiel du HD44780 (adressage DDRAM entrelace des
;            afficheurs 4 lignes "type A" - LCD_LINE3/4 suivent
;            directement LCD_LINE1/2 en memoire interne) et peut
;            deborder sur une AUTRE ligne visible - pas d'ecretage
;            logiciel. Registres:
;              BH = peripherique cible: 1 = LCD parallele,
;                   2 = LCD I2C (PCF8574) - toute autre valeur est
;                   ignoree (aucun affichage).
;              BL = couleur - actuellement SANS EFFET (reservee pour
;                   une prochaine version: sortie couleur via codes
;                   ANSI sur l'UART - voir Directives.md).
;              CX = nombre de repetitions (0 = aucun effet).
;            Le curseur logique N'EST PAS deplace par cet appel (meme
;            comportement que le vrai BIOS AH=09h) - un appel
;            ulterieur a AH=02h est necessaire pour ecrire ailleurs.
;
; Toute autre valeur de AH est ignoree (retour immediat).
; ============================================================
int10h_handler:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        cmp     ah, 02h
        je      .set_cursor
        cmp     ah, 09h
        je      .write_char
        jmp     .done

.set_cursor:
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_CURSOR_ROW_OFF
        mov     [es:di], dh
        mov     di, BIOS_CURSOR_COL_OFF
        mov     [es:di], dl
        jmp     .done

.write_char:
        cmp     cx, 0
        je      .done                            ; rien a ecrire

        mov     bp, ax                           ; BP = caractere original (AL) -
                                                   ; AX va servir de scratch pour
                                                   ; acceder a VAR_SEG
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, BIOS_CURSOR_ROW_OFF
        mov     dh, [es:di]                      ; DH = ligne
        mov     di, BIOS_CURSOR_COL_OFF
        mov     dl, [es:di]                      ; DL = colonne
        call    bios_cursor_ddram                ; AH = adresse DDRAM (DH/DL consommes)

        mov     al, ah
        or      al, 80h                          ; AL = commande "Set DDRAM Address"

        cmp     bh, 1
        je      .dev_lcd
        cmp     bh, 2
        je      .dev_i2c
        jmp     .done                            ; peripherique non reconnu - ignore

.dev_lcd:
        call    lcd_command                      ; positionne le curseur materiel
        mov     ax, bp                           ; restaure AL = caractere
.dev_lcd_loop:
        call    lcd_data
        loop    .dev_lcd_loop
        jmp     .done

.dev_i2c:
        call    i2c_lcd_command                  ; positionne le curseur materiel
        mov     ax, bp                           ; restaure AL = caractere
.dev_i2c_loop:
        call    i2c_lcd_data
        loop    .dev_i2c_loop

.done:
        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret

; ============================================================
; int16h_handler
; Gestionnaire de INT 16h (clavier), sous-ensemble "esprit BIOS":
;
;   AH=01h - Lecture NON BLOQUANTE d'une touche: verifie CLOCK (PB0),
;            HAUT au repos (voir lib/ps2.asm), avant de lire une
;            trame en cours - meme technique que l'interruption
;            Echap de dump_memory_action. Si une touche est
;            disponible, elle est CONSOMMEE (ce projet, en polling
;            pur, n'a pas de tampon clavier permettant un "peek" sans
;            consommer, contrairement au vrai BIOS IBM PC - seule
;            approximation raisonnable ici).
;              Sortie: AH = scan code PS/2 Set 2 BRUT (voir
;                ps2_get_char), AL = caractere ASCII (ou PS2_KEY_*),
;                ZF=0 si une touche a ete lue. Si aucune touche
;                n'est disponible: AX=0, ZF=1.
;            IMPORTANT: le registre FLAGS restitue par IRET est celui
;            EMPILE PAR L'INSTRUCTION INT (pas l'etat courant du CPU)
;            - ce gestionnaire doit donc ecraser directement ce mot
;            sur la pile pour que le ZF ci-dessus soit visible a
;            l'appelant apres IRET (technique standard, voir
;            .set_flags plus bas). AX N'EST PAS PRESERVE (c'est la
;            sortie voulue) - BX/CX/DX/SI/DI/BP/ES le sont.
;
; Toute autre valeur de AH est ignoree (IRET immediat, flags et
; registres inchanges).
; ============================================================
int16h_handler:
        cmp     ah, 01h
        jne     .passthrough

        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        in      al, PORTB
        test    al, PS2_CLOCK
        jnz     .no_key                          ; CLOCK haut (repos) - rien a lire

        call    ps2_get_char                     ; AL=caractere ASCII (ou PS2_KEY_*),
                                                   ; BH=scan code PS/2 brut
        mov     ah, bh                           ; AH = scan code (sortie)
        or      al, al                           ; ZF=0 (touche lue) - AL non nul
                                                   ; en pratique pour toute touche geree
        jmp     .set_flags

.no_key:
        xor     ax, ax                           ; AX=0
        or      al, al                           ; ZF=1 explicite

.set_flags:
        ; --- ecrase le mot FLAGS empile par l'instruction INT (celui
        ; qu'IRET va restituer) avec les flags courants (le ZF pose
        ; ci-dessus par "or al,al") - le 8086 ne permet pas [SP+depl]
        ; directement, d'ou BP, fige AVANT le "pushf" (qui deplace SP
        ; mais pas BP). [bp+18] = 14 octets deja empiles ci-dessus
        ; (bx/cx/dx/si/di/bp/es) + 4 (IP+CS empiles par INT avant
        ; FLAGS) = position du mot FLAGS original. ---
        mov     bp, sp
        pushf
        pop     word [bp+18]

        pop     es
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        iret

.passthrough:
        iret

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

; ---- bandeau de dump_memory_action: "=== Dump memoire: SSSS:OOOO a
; ---- SSSS:OOOO ===" - les adresses (saisies au clavier) sont
; ---- inserees entre ces 3 fragments par le code lui-meme ----
txt_dump_banniere1:      db      27,'[34m','=== Dump memoire: ',0
txt_dump_banniere2:      db      ' a ',0
txt_dump_banniere3:      db      ' ===',27,'[0m',13,10,0

txt_dump_fin:            db      27,'[32m','*** Dump termine ***',27,'[0m',13,10,13,10,0

txt_dump_invalid_range: db      27,'[31m','*** Adresse de fin < adresse de depart - dump annule ***',27,'[0m',13,10,13,10,0

txt_dump_interrupted:   db      27,'[33m','*** Dump interrompu (Echap) ***',27,'[0m',13,10,13,10,0

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
                        db      '1) Dump memory',13,10
                        db      '2) Edit RAM',13,10
                        db      '9) Home menu',13,10,13,10,0

; ---- invite "Edit RAM" (voir edit_ram_action) ----
txt_edit_address_prefix: db     'Address: 0x', 0
txt_edit_help:           db     27,'[36m','Fleches: deplacer | chiffre hexa: editer | Entree: enregistrer | Q: quitter',27,'[0m',13,10,13,10,0

; ---- invites "Dump memory" (voir dump_memory_action) - "End:   0x"
; ---- a la meme longueur (9) que "Start: 0x" pour que les chiffres
; ---- de segment se retrouvent a la meme colonne DDRAM sur les
; ---- lignes 1/2 du LCD ----
txt_dump_start_prefix:  db      'Start: 0x', 0
txt_dump_end_prefix:    db      'End:   0x', 0
txt_dump_seg_off_sep:   db      ':0x', 0

; ---- texte du LCD I2C (PCF8574 0x27) - pas de padding, pas de
; ---- largeur fixe imposee comme sur le LCD parallele. Les lignes
; ---- 1/2/4 de l'ecran de demarrage I2C reutilisent directement
; ---- lcd_txt_splash_l1/l2/l4 (voir start:) - seule la ligne 3 (les
; ---- parametres de connexion UART) est specifique a l'I2C ----
i2c_txt_uart_params:    db      'UART: 9600 8N1', 0

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

; ---- menu Dump memory (voir start:) - seules les lignes 1/2/4 sont
; ---- utilisees (ligne 3 laissee vide par lcd_init) ----
lcd_text lcd_txt_menu_dump_l1, '1) Dump memory', 20
lcd_text lcd_txt_menu_dump_l2, '2) Edit RAM', 20
lcd_text lcd_txt_menu_dump_l4, '9) Home menu', 20

; ---- bandeau ligne1/ligne2 affiche avant chaque action lancee depuis
; ---- un menu (lignes 3/4 sont mises a jour en direct par l'action
; ---- elle-meme - voir start:) ----
lcd_text lcd_txt_run_ram_l1, 'Test RAM 128K', 20
lcd_text lcd_txt_run_ram_l2, 'En cours...', 20

lcd_text lcd_txt_run_led_l1, 'Test 8255', 20
lcd_text lcd_txt_run_led_l2, 'Chenillard Port C', 20
lcd_text lcd_txt_run_led_l4, 'VE2CUY 2026', 20

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

; ---- ligne 4 de l'etape 3 (dump_line): "Ligne: " + dec3 + 10
; ---- espaces = 7+3+10 = 20 caracteres. Pas de "/total": la plage
; ---- dumpee est desormais de taille variable (dump_memory_action) -
; ---- voir sa limitation connue (lcd_tx_dec3, 0-999 lignes) ----
lcd_txt_ligne_prefix:   db      'Ligne: ', 0
lcd_text lcd_txt_ligne_suffix, '', 10

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
