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
        print   CLS, UART       ; efface l'ecran du terminal (ANSI)
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

; --- uart_flag_bit: affiche via l'UART le mnemonique DEBUG.COM (2
; --- lettres) correspondant a UN bit du registre FLAGS - utilise 8
; --- fois par registers_dump_action pour le decodage "ergonomique"
; --- des FLAGS (ordre classique OF DF IF SF ZF AF PF CF). Le
; --- mnemonique "actif" (bit=1) est colore en jaune pour ressortir a
; --- l'oeil; le mnemonique "inactif" (bit=0) reste en couleur par
; --- defaut du terminal - voir les paires txt_flag_*_set/clear plus
; --- bas dans la section donnees. Chaque etiquette inclut deja un
; --- espace de separation final (voir leur definition).
; --- %1=masque (mot), %2=etiquette si le bit est a 1, %3=etiquette
; --- si le bit est a 0. DX DOIT deja contenir le mot FLAGS a decoder
; --- (charge une seule fois par l'appelant, avant la 1ere invocation). ---
%macro uart_flag_bit 3
        test    dx, %1
        jz      %%is_clear
        print   %2, UART
        jmp     %%done
%%is_clear:
        print   %3, UART
%%done:
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

        ; --- Efface TOUTE la RAM (128K: segments 0000h et 1000h) a 0,
        ; AVANT quoi que ce soit d'autre - elimine le "garbage"
        ; residuel visible dans les dumps memoire (RAM statique sans
        ; valeur garantie a la mise sous tension). ECRIT EN LIGNE (pas
        ; de CALL): le segment 1000h contient la pile deja active
        ; (SS/SP ci-dessus) - un retour d'appel qui s'y trouverait
        ; serait efface par erreur. Sans risque ICI puisque rien n'a
        ; encore ete empile a ce stade. AX reste a 0 (valeur de
        ; remplissage de "rep stosw") tout du long - CX sert de
        ; registre de transfert pour le 2e segment. ---
        xor     ax, ax
        mov     es, ax
        xor     di, di
        mov     cx, 8000h       ; 32768 mots = 65536 octets (segment 0000h)
        rep     stosw
        mov     cx, STACK_SEG   ; CX = transfert (AX doit rester a 0)
        mov     es, cx
        xor     di, di
        mov     cx, 8000h       ; segment 1000h (STACK_SEG/VAR_SEG)
        rep     stosw

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

        call    init_ivt_not_implemented  ; peuple les 256 entrees de l'IVT
                                            ; avec un gestionnaire generique
                                            ; ("non implementee" - voir plus
                                            ; bas), AVANT nos propres vecteurs
        call    setup_bios_interrupts  ; installe ENSUITE INT 10h/16h
                                         ; ("esprit BIOS" - voir plus bas),
                                         ; par-dessus les 2 entrees concernees

%ifdef TEST_PS2
        ; --- Test PS/2 (TEST_PS2): boucle infinie qui affiche sur
        ; l'UART le scan code (Set 2, brut) de chaque trame recue du
        ; clavier, en polling pur (Port B du 8255, deja configure en
        ; ENTREE par init_8255/MASQUE_PIO ci-dessus). REMPLACE le
        ; reste du POST - voir lib/ps2.asm et la note pres de
        ; %define TEST_PS2 en haut du fichier. Ne retourne JAMAIS. ---
        print   txt_ps2_attente, UART
.ps2_loop:
        call    ps2_read_byte    ; bloque - AL=scan code recu, CF=1 si trame invalide
        pushf                    ; CF doit survivre aux appels UART qui suivent
                                  ; (AL, lui, est deja preserve par uart_tx_string)
        mov     si, txt_ps2_recu
        call    uart_tx_string
        call    uart_tx_hex_byte ; affiche le scan code en hexa (AL toujours valide)
        popf
        jnc     .ps2_ok
        print   txt_ps2_erreur, UART
        jmp     .ps2_next
.ps2_ok:
        print   txt_crlf, UART
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
        gotoxy  0, 0, LCDI2C
        print   lcd_txt_splash_l1, LCDI2C      ; "Breadboard 8088"
        gotoxy  1, 0, LCDI2C
        print   lcd_txt_splash_l2, LCDI2C      ; "Version 1.0"
        gotoxy  2, 0, LCDI2C
        print   i2c_txt_uart_params, LCDI2C    ; "UART: 9600 8N1"
        gotoxy  3, 0, LCDI2C
        print   lcd_txt_splash_l4, LCDI2C      ; "(c) VE2CUY 2026"

        ; --- Ecran de demarrage: affiche une seule fois (pas a chaque
        ; cycle de .ici, contrairement au reste de l'affichage LCD),
        ; pendant 1 seconde, avant d'entrer dans la boucle principale.
        ; Affiche via INT 10h (gotoxy/print, voir include/lcd_macros.inc)
        ; plutot que lcd_goto/lcd_print directement - premier usage
        ; reel de l'interface "esprit BIOS" (voir int10h_handler,
        ; README.md) ---
        call    lcd_init
        gotoxy  0, 0, LCD
        print   lcd_txt_splash_l1, LCD
        gotoxy  1, 0, LCD
        print   lcd_txt_splash_l2, LCD
        gotoxy  2, 0, LCD
        print   lcd_txt_splash_l3, LCD
        gotoxy  3, 0, LCD
        print   lcd_txt_splash_l4, LCD
        delay_ms (1*SECONDE)

        ; --- Bandeau d'identification: affiche une seule fois, avant
        ; d'entrer dans le menu (remplace l'ancienne boucle POST
        ; automatique .ici:/.temp: - voir Directives.md: le menu
        ; interactif, pilote par le clavier PS/2, est maintenant le
        ; comportement normal) ---
        cls                     ; efface l'ecran du terminal (ANSI)
        print   txt_auteur, UART

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
        print   txt_menu_main, UART
        gotoxy  0, 0, LCD
        print   lcd_txt_menu_main_l1, LCD
        gotoxy  1, 0, LCD
        print   lcd_txt_menu_main_l2, LCD
        gotoxy  2, 0, LCD
        print   lcd_txt_menu_main_l3, LCD
        gotoxy  3, 0, LCD
        print   lcd_txt_menu_main_l4, LCD

        call    ps2_get_char            ; bloque jusqu'a une touche reconnue

        cmp     al, '1'
        jne     .main_2
        call    lcd_init
        gotoxy  0, 0, LCD
        print   lcd_txt_run_ram_l1, LCD
        gotoxy  1, 0, LCD
        print   lcd_txt_run_ram_l2, LCD
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
        gotoxy  0, 0, LCD
        print   lcd_txt_run_led_l1, LCD
        gotoxy  1, 0, LCD
        print   lcd_txt_run_led_l2, LCD
        gotoxy  3, 0, LCD
        print   lcd_txt_run_led_l4, LCD ; texte fixe (ligne 3 = progression
                                         ; live, mise a jour par effet1)
        call    effet1                  ; animation Port C (chenillard)
        jmp     .main_menu
.main_4:
        cmp     al, '4'
        jne     .main_menu              ; touche non reconnue - redessine le menu
        call    edit_ram_action
        jmp     .main_menu

.dump_menu:
        call    lcd_init
        print   txt_menu_dump, UART
        gotoxy  0, 0, LCD
        print   lcd_txt_menu_dump_l1, LCD
        gotoxy  1, 0, LCD
        print   lcd_txt_menu_dump_l2, LCD
        gotoxy  2, 0, LCD
        print   lcd_txt_menu_dump_l3, LCD
        gotoxy  3, 0, LCD
        print   lcd_txt_menu_dump_l4, LCD

        call    ps2_get_char

        cmp     al, '1'
        jne     .dump_2
        call    dump_memory_action      ; demande adresses depart/fin, dump - voir plus bas
        jmp     .dump_menu
.dump_2:
        cmp     al, '2'
        jne     .dump_3
        call    edit_ram_action
        jmp     .dump_menu
.dump_3:
        cmp     al, '3'
        jne     .dump_4
        call    registers_dump_action   ; affiche les registres du 8088 (LCD+UART) - voir plus bas
        jmp     .dump_menu
.dump_4:
        cmp     al, '4'
        jne     .dump_esc
        call    edit_run_action         ; edite/execute a 1000:0000 - voir plus bas
        jmp     .dump_menu
.dump_esc:
        cmp     al, 27                  ; Echap: retour au menu principal (remplace
        jne     .dump_menu              ; l'ancienne option "9) Home menu", non
        jmp     .main_menu              ; affichee - touche non reconnue: redessine le menu

; ============================================================
; test_ram
; Teste la totalite de la RAM statique de 128K (00000h-1FFFFh),
; par blocs de 64K (2 segments: 0000h et 1000h), moins les 2 derniers
; Ko du segment 1000h reserves a la pile active, a la copie fantome
; du port A, au tampon d'edition de edit_ram_action et aux autres
; variables partagees (PORTA_SHADOW_OFF = tout debut de cette zone,
; voir en en-tete).
; Resultat: 129024 octets testes sur 131072 (126 blocs de 1 Ko).
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

        ; --- Segment 1000h: physique 10000h-1FFFFh, moins les 2       ---
        ; --- derniers Ko reserves a la pile -> 63488 octets testes    ---
        mov     ax, STACK_SEG
        mov     es, ax
        xor     di, di
        mov     cx, 63488       ; 65536 - 2048 (zone reservee a la pile, au
                                 ; tampon d'edition et aux autres variables
                                 ; partagees - voir en en-tete de hardware.inc)
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
; toute la RAM, 128 Ko), TOUT l'espace d'adressage materiel en une
; seule fois (0000:0000 a F000:FFFF, jusqu'a l'adresse physique
; FFFFFh - 20 lignes d'adresse, voir le piege FFFF:FFFx dans
; README.md) ou n'importe quelle plage intermediaire - plus besoin de
; deux procedures separees.
;
; La plage peut traverser une frontiere de segment (ex: 0000:FFF0 a
; 1000:0010, ou meme plusieurs dizaines de segments d'affilee):
; l'offset (DI) est avance de 16 a chaque ligne comme avant; en cas de
; debordement (DI redevient <= sa valeur d'avant l'ajout), le segment
; (ES) est avance de 1000h pour rester a la bonne adresse physique
; (1 paragraphe = 16 octets = 1000h en unites de segment) - SAUF si
; cet ajout deborde LUI-MEME 16 bits (ES etait deja F000h-FFFFh): la
; plage maximale de ce materiel vient alors d'etre entierement
; couverte, le dump s'arrete plutot que de continuer sur un segment
; errone (qui reviendrait a 0000h).
;
; L'arret normal (hors ce cas limite) compare l'adresse physique
; COURANTE (32 bits) a l'adresse physique de fin a CHAQUE ligne,
; plutot que de precalculer un nombre total de lignes: pour la plage
; maximale ci-dessus, ce total vaudrait exactement 65536, qui NE TIENT
; PAS dans un mot de 16 bits (deborderait silencieusement a 0).
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

        ; --- memorise end_phys (32 bits) - compare a l'adresse
        ; physique COURANTE a chaque ligne (voir .line_loop plus bas)
        ; plutot que de precalculer un nombre total de lignes: pour la
        ; plage maximale de ce materiel (0000:0000 a F000:FFFF), ce
        ; total vaudrait exactement 65536, qui NE TIENT PAS dans un
        ; mot de 16 bits (deborderait a 0) ---
        mov     bx, VAR_SEG
        mov     es, bx
        mov     di, DUMP_END_PHYS_LO_OFF
        mov     [es:di], ax
        mov     di, DUMP_END_PHYS_HI_OFF
        mov     [es:di], dx

        pop     cx                              ; CX = start_phys (poids faible)
        pop     bp                              ; BP = start_phys (poids fort)

        cmp     dx, bp
        jb      .invalid_range
        ja      .range_ok
        cmp     ax, cx
        jb      .invalid_range
.range_ok:
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
        ; --- debordement 16 bits de DI: avance le segment d'un
        ; --- paragraphe (1000h). SI CET AJOUT DEBORDE AUSSI (CF=1,
        ; --- ES etait deja F000h-FFFFh), la plage maximale de ce
        ; --- materiel (jusqu'a l'adresse physique FFFFFh) vient
        ; --- d'etre entierement couverte: on s'arrete plutot que de
        ; --- continuer sur un segment errone (revenu a 0000h) ---
        mov     ax, es
        add     ax, 1000h
        jc      .dump_complete
        mov     es, ax
.no_wrap:
        inc     bx

        ; --- adresse physique COURANTE (ES:DI, apres cette ligne) -
        ; --- comparee a end_phys (32 bits, en RAM): continue tant que
        ; --- current <= end_phys. BX (numero de ligne) sauvegarde
        ; --- autour de l'appel a mem_calc_physical (qui utilise BX
        ; --- pour l'offset en entree) ---
        push    bx
        mov     ax, es
        mov     bx, di
        call    mem_calc_physical               ; DX:AX = adresse physique courante
        pop     bx

        ; --- BP adresse VAR_SEG directement via SS (= VAR_SEG en
        ; --- PERMANENCE depuis l'init de la pile, voir start:) - pas
        ; --- besoin de sauvegarder/restaurer ES (segment du dump) ---
        push    bp
        mov     bp, DUMP_END_PHYS_HI_OFF
        cmp     dx, [bp]
        ja      .dump_complete_popbp
        jb      .continue_popbp
        mov     bp, DUMP_END_PHYS_LO_OFF
        cmp     ax, [bp]
        ja      .dump_complete_popbp
.continue_popbp:
        pop     bp
        jmp     .line_loop
.dump_complete_popbp:
        pop     bp
.dump_complete:
        call    msg_dump_fin
        jmp     .done

.interrupted:
        print   txt_dump_interrupted, UART
        jmp     .done

.invalid_range:
        print   txt_dump_invalid_range, UART

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

EDIT_COLS               equ     5               ; octets par ligne de la grille d'edition - 5
                                                  ; (pas 6): laisse exactement la place pour
                                                  ; l'etiquette d'adresse "SSSS:" (5 caracteres,
                                                  ; EDIT_ADDR_LABEL_WIDTH) en tete de chaque
                                                  ; ligne LCD sans depasser les 20 caracteres
                                                  ; disponibles (5 + 5*3 = 20 exactement) - voir
                                                  ; edit_ram_draw_grid/cell_ddram.
EDIT_ADDR_LABEL_WIDTH   equ     5               ; largeur de l'etiquette d'adresse LCD ("SSSS:")
EDIT_ROWS               equ     4               ; lignes VISIBLES a la fois (4 lignes du LCD)
EDIT_MAX_SIZE           equ     0400h           ; taille maximale d'une plage editable (1024)
EDIT_MIN_START          equ     0400h           ; adresse de depart minimale (juste apres
                                                  ; l'IVT, 256*4=1024 octets - voir
                                                  ; "Interruptions logicielles type BIOS",
                                                  ; README.md)
EDIT_RUN_SIZE           equ     0FFh            ; taille FIXE (255 octets) de la plage
                                                  ; editable/executable a 1000:0000 (voir
                                                  ; edit_run_action) - pas de saisie, valeur
                                                  ; imposee (demande explicite)

; ============================================================
; edit_ram_action
; Editeur de RAM interactif, PAR PLAGE et AVEC TAMPON (annulation
; possible) - remplace la version a adresse unique du premier jalon
; (voir Directives.md).
;
; Demande, avec retour arriere possible sur chaque saisie (voir
; ps2_read_hex_editable):
;   1) une adresse de DEPART (4 chiffres hexa) - DOIT etre >=
;      EDIT_MIN_START (0400h, juste apres l'IVT): une adresse dans
;      l'IVT est REJETEE (message d'erreur, retour immediat au menu)
;      pour ne jamais pouvoir corrompre les gestionnaires
;      d'interruption.
;   2) une TAILLE en octets (4 chiffres hexa) - DOIT etre entre 1 et
;      EDIT_MAX_SIZE (400h = 1024) inclusivement, ET la plage
;      resultante (depart+taille-1) ne doit pas depasser 0FFFFh
;      (rester dans le segment 0000h) - sinon, meme rejet.
;
; Contrairement au premier jalon, RIEN N'EST ECRIT DANS LA VRAIE RAM
; PENDANT L'EDITION: tous les octets de la plage sont copies dans un
; TAMPON de travail (EDIT_BUFFER_OFF, VAR_SEG - voir
; edit_ram_load_buffer) des le depart, et l'edition ne modifie QUE ce
; tampon:
;   Echap - ANNULE toute l'edition: le tampon est abandonne, la RAM
;           reelle n'est PAS modifiee, retour immediat au menu.
;   Q/q   - VALIDE: le tampon (taille octets) est recopie dans la RAM
;           reelle (voir edit_ram_commit_buffer), puis retour au menu.
;
; La grille affiche EDIT_ROWS x EDIT_COLS (4x5 = 20) octets a la fois,
; mais la plage peut en contenir jusqu'a 1024 (soit jusqu'a 205 lignes
; logiques): les fleches HAUT/BAS FONT DEFILER la fenetre visible d'une
; ligne des que le curseur en sortirait (voir edit_ram_move_up/down et
; edit_ram_scroll_to_cursor) - contrairement au premier jalon, limite
; a la grille initialement affichee.
;
;   Fleches G/D  - deplacent la case courante DANS SA LIGNE (fixees
;                  aux bords de colonne, comme avant).
;   Fleches H/B  - deplacent la case courante d'UNE LIGNE LOGIQUE
;                  (fixees aux bords de la plage), avec defilement de
;                  la fenetre visible si necessaire.
;   chiffre hexa - compose une nouvelle valeur pour la case courante
;                  (1 ou 2 chiffres, retour arriere - voir
;                  ps2_edit_byte_value), ecrite DANS LE TAMPON.
;   Entree       - valide la saisie dans le tampon (ignoree si aucun
;                  chiffre tape), avance a la case suivante (voir
;                  edit_ram_advance).
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

        ; --- adresse de depart ---
        mov     si, txt_edit_address_prefix
        call    uart_tx_string
        mov     si, txt_edit_address_prefix
        lcd_show LCD_LINE1
        mov     cl, 4
        mov     ah, (LCD_LINE1 & 07Fh) + 11     ; 11 = longueur de "Address: 0x"
        call    ps2_read_hex_editable           ; BX = adresse saisie

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte

        cmp     bx, EDIT_MIN_START
        jae     .start_ok
        print   txt_edit_ivt_reject, UART
        jmp     .done
.start_ok:
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     [es:di], bx                     ; memorise l'adresse de depart

        ; --- taille de la plage (en octets) ---
        mov     si, txt_edit_size_prefix
        call    uart_tx_string
        mov     si, txt_edit_size_prefix
        lcd_show LCD_LINE2
        mov     cl, 4
        mov     ah, (LCD_LINE2 & 07Fh) + 11     ; 11 = longueur de "Size:    0x"
        call    ps2_read_hex_editable           ; BX = taille saisie

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte

        cmp     bx, 0
        je      .size_reject
        cmp     bx, EDIT_MAX_SIZE
        ja      .size_reject

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     ax, [es:di]                     ; AX = adresse de depart
        mov     cx, bx                          ; CX = taille
        dec     cx                              ; CX = taille-1
        add     ax, cx                          ; AX = dernier octet de la plage
        jc      .size_reject                    ; deborde 0FFFFh - invalide
        jmp     .size_ok
.size_reject:
        print   txt_edit_size_invalid, UART
        jmp     .done
.size_ok:
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_SIZE_OFF
        mov     [es:di], bx

        print   txt_edit_help, UART

        call    edit_ram_load_buffer            ; copie la plage reelle -> tampon

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_CURSOR_OFF
        mov     word [es:di], 0
        mov     di, EDIT_WINDOW_ROW_OFF
        mov     word [es:di], 0

.redraw:
        call    edit_ram_draw_grid

.wait_key:
        call    ps2_get_char

        cmp     al, 27                          ; Echap: annule (rien recopie)
        je      .done

        cmp     al, 'q'
        je      .commit
        cmp     al, 'Q'
        je      .commit

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
        call    edit_ram_write_current   ; ecrit DANS LE TAMPON
        call    edit_ram_advance         ; passe a la case suivante (ordre de lecture)
        jmp     .redraw

.commit:
        call    edit_ram_commit_buffer          ; recopie le tampon -> RAM reelle

.done:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_load_buffer
; Copie EDIT_SIZE_OFF octets de la RAM reelle (segment 0000h, a partir
; de EDIT_BASE_OFF) dans le tampon de travail (EDIT_BUFFER_OFF,
; VAR_SEG) - appelee une fois au debut de l'edition. BP adresse
; VAR_SEG directement via SS (= VAR_SEG en PERMANENCE depuis l'init de
; la pile, voir start:) - [BP] utilise SS par defaut sur le 8086, pas
; besoin de changer ES pour lire les constantes ni de toucher a DS.
; ============================================================
edit_ram_load_buffer:
        push    ax
        push    cx
        push    dx
        push    si
        push    bp
        push    es

        mov     bp, EDIT_BASE_OFF
        mov     dx, [bp]                ; DX = adresse de depart (RAM reelle)
        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille (nombre d'octets a copier)

        xor     ax, ax
        mov     es, ax                  ; ES = 0000h (RAM reelle, source)
        mov     si, dx                  ; SI = adresse source courante

        mov     bp, EDIT_BUFFER_OFF     ; BP = pointeur destination (tampon, via SS)
.copy_loop:
        mov     al, [es:si]
        mov     [bp], al
        inc     si
        inc     bp
        loop    .copy_loop

        pop     es
        pop     bp
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; edit_ram_commit_buffer
; Recopie EDIT_SIZE_OFF octets du tampon de travail (EDIT_BUFFER_OFF)
; vers la RAM reelle (segment 0000h, a partir de EDIT_BASE_OFF) -
; appelee UNIQUEMENT sur validation (Q/q), jamais sur Echap. Symetrique
; de edit_ram_load_buffer (voir son en-tete).
; ============================================================
edit_ram_commit_buffer:
        push    ax
        push    cx
        push    dx
        push    di
        push    bp
        push    es

        mov     bp, EDIT_BASE_OFF
        mov     dx, [bp]                ; DX = adresse de depart (RAM reelle)
        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille

        xor     ax, ax
        mov     es, ax                  ; ES = 0000h (RAM reelle, destination)
        mov     di, dx                  ; DI = adresse destination courante

        mov     bp, EDIT_BUFFER_OFF     ; BP = pointeur source (tampon, via SS)
.copy_loop:
        mov     al, [bp]
        mov     [es:di], al
        inc     di
        inc     bp
        loop    .copy_loop

        pop     es
        pop     bp
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; edit_run_load_buffer / edit_run_commit_buffer
; Copies STRICTEMENT IDENTIQUES a edit_ram_load_buffer/commit_buffer
; (voir ci-dessus), sauf que le cote "RAM reelle" vise le SEGMENT
; 1000h (VAR_SEG/STACK_SEG) au lieu de 0000h - utilisees par
; edit_run_action (voir plus bas, apres registers_dump_action) pour
; editer/executer du code place a 1000:0000 (deuxieme bloc de 64K de
; RAM). EDIT_BASE_OFF est TOUJOURS 0000h pour ces deux routines
; (adresse fixe, imposee par edit_run_action - pas de saisie
; d'adresse comme dans edit_ram_action).
; ============================================================
edit_run_load_buffer:
        push    ax
        push    cx
        push    dx
        push    si
        push    bp
        push    es

        mov     bp, EDIT_BASE_OFF
        mov     dx, [bp]                ; DX = adresse de depart (toujours 0000h ici)
        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille (nombre d'octets a copier)

        mov     ax, VAR_SEG
        mov     es, ax                  ; ES = 1000h (RAM reelle, source)
        mov     si, dx                  ; SI = adresse source courante

        mov     bp, EDIT_BUFFER_OFF     ; BP = pointeur destination (tampon, via SS)
.copy_loop:
        mov     al, [es:si]
        mov     [bp], al
        inc     si
        inc     bp
        loop    .copy_loop

        pop     es
        pop     bp
        pop     si
        pop     dx
        pop     cx
        pop     ax
        ret

edit_run_commit_buffer:
        push    ax
        push    cx
        push    dx
        push    di
        push    bp
        push    es

        mov     bp, EDIT_BASE_OFF
        mov     dx, [bp]                ; DX = adresse de depart (toujours 0000h ici)
        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille

        mov     ax, VAR_SEG
        mov     es, ax                  ; ES = 1000h (RAM reelle, destination)
        mov     di, dx                  ; DI = adresse destination courante

        mov     bp, EDIT_BUFFER_OFF     ; BP = pointeur source (tampon, via SS)
.copy_loop:
        mov     al, [bp]
        mov     [es:di], al
        inc     di
        inc     bp
        loop    .copy_loop

        pop     es
        pop     bp
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; edit_ram_draw_grid
; (Re)affiche les EDIT_ROWS (4) lignes VISIBLES a partir de
; EDIT_WINDOW_ROW_OFF (ligne logique du haut), en lisant les valeurs
; dans le TAMPON (EDIT_BUFFER_OFF) - PAS la RAM reelle. L'adresse
; affichee au debut de chaque ligne reste la vraie adresse RAM
; (EDIT_BASE_OFF + decalage), pour que l'utilisateur s'y retrouve. Les
; lignes au-dela de la taille de la plage restent vides. Termine en
; positionnant le curseur materiel du LCD (edit_ram_place_cursor).
;
; IMPORTANT: EDIT_SIZE_OFF et EDIT_WINDOW_ROW_OFF sont RELUS a chaque
; ligne (pas gardes dans BX/CX d'une iteration a l'autre): un bug a
; ete trouve et corrige AVANT deploiement ou BX (fenetre) etait
; ecrase par le nombre de colonnes valides de la ligne precedente,
; corrompant le calcul de la ligne suivante.
; ============================================================
edit_ram_draw_grid:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    es

        call    lcd_init

        xor     si, si                  ; SI = ligne VISIBLE courante (0-3)
.row_loop:
        mov     bp, EDIT_WINDOW_ROW_OFF
        mov     ax, [bp]                ; AX = ligne logique du haut de la fenetre
        add     ax, si                  ; AX = ligne logique de CETTE ligne visible
        mov     dx, EDIT_COLS
        mul     dx                      ; AX = ligne logique * EDIT_COLS (tient dans
                                          ; AX, max 204*5=1020)
        mov     di, ax                  ; DI = decalage (octets) du 1er octet de
                                          ; cette ligne dans la plage/le tampon

        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille totale (relue a chaque ligne)
        cmp     di, cx
        jae     .row_blank              ; au-dela de la plage - ligne vide

        ; --- selectionne la ligne LCD (0-3 -> LCD_LINE1-4) ---
        cmp     si, 0
        jne     .row_not0
        lcd_goto LCD_LINE1
        jmp     .row_go
.row_not0:
        cmp     si, 1
        jne     .row_not1
        lcd_goto LCD_LINE2
        jmp     .row_go
.row_not1:
        cmp     si, 2
        jne     .row_not2
        lcd_goto LCD_LINE3
        jmp     .row_go
.row_not2:
        lcd_goto LCD_LINE4
.row_go:
        ; --- adresse REELLE de cette ligne (EDIT_BASE_OFF + DI), sur le
        ; LCD ET l'UART. Sur le LCD: "SSSS:" (EDIT_ADDR_LABEL_WIDTH = 5
        ; caracteres, SANS espace apres les deux-points - contrairement
        ; a l'UART qui, lui, n'est pas contraint en largeur) + EDIT_COLS
        ; (5) cases "XX " (15 caracteres) = EXACTEMENT 20 caracteres,
        ; la largeur du LCD - AUCUN debordement. EDIT_COLS a ete reduit
        ; de 6 a 5 PRECISEMENT pour degager cette place: avec 6 cases
        ; (18 caracteres), ajouter la moindre etiquette d'adresse
        ; depasserait 20 et deborderait dans la ligne PAIREE (LCD_LINE1
        ; <->LCD_LINE3, LCD_LINE2<->LCD_LINE4 partagent le meme bloc de
        ; 40 octets de DDRAM) - bug deja trouve et corrige sur le
        ; materiel reel avec l'ancien format 6 cases + etiquette (voir
        ; Directives.md); NE PAS reaugmenter EDIT_COLS sans retirer
        ; l'etiquette, ou l'inverse. AX necessaire deux fois (LCD PUIS
        ; UART, chacun le detruit - voir leurs contrats) - preserve via
        ; push/pop plutot que de relire EDIT_BASE_OFF+DI deux fois. ---
        mov     bp, EDIT_BASE_OFF
        mov     ax, [bp]
        add     ax, di                  ; AX = adresse reelle de cette ligne
        push    ax
        call    lcd_tx_hex_word
        mov     al, ':'
        call    lcd_data
        pop     ax
        call    uart_tx_hex_word
        mov     al, ':'
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte

        ; --- nombre de colonnes valides pour cette ligne (EDIT_COLS,
        ; sauf la derniere ligne logique si la taille n'est pas
        ; multiple de EDIT_COLS) ---
        mov     ax, cx
        sub     ax, di                  ; AX = octets restants a partir d'ici
        cmp     ax, EDIT_COLS
        jbe     .cols_ok
        mov     ax, EDIT_COLS
.cols_ok:
        mov     bl, al                  ; BL = nombre de colonnes valides (1-5)

        mov     bp, EDIT_BUFFER_OFF
        add     bp, di                  ; BP = pointeur tampon, debut de cette ligne
        xor     dh, dh                  ; DH = colonne courante (0-4)
.col_loop:
        cmp     dh, bl
        jae     .col_pad
        mov     al, [bp]
        mov     ah, al                  ; AH = copie (survit a lcd_tx_hex_byte -
                                          ; jamais touche, voir def_tx_hex_*)
        call    lcd_tx_hex_byte
        mov     al, ah
        call    uart_tx_hex_byte
        mov     al, ' '
        call    lcd_data
        mov     al, ' '
        call    uart_tx_byte
        inc     bp
        jmp     .col_next
.col_pad:
        ; --- au-dela des octets valides de cette derniere ligne
        ; partielle: espaces sur le LCD seulement (garde la grille
        ; alignee) - rien sur l'UART ---
        mov     al, ' '
        call    lcd_data
        mov     al, ' '
        call    lcd_data
        mov     al, ' '
        call    lcd_data
.col_next:
        inc     dh
        cmp     dh, EDIT_COLS
        jb      .col_loop

        mov     al, 13
        call    uart_tx_byte
        mov     al, 10
        call    uart_tx_byte

.row_blank:
        inc     si
        cmp     si, EDIT_ROWS
        jb      .row_loop

        call    edit_ram_place_cursor

        pop     es
        pop     bp
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
; COURANTE (EDIT_CURSOR_OFF, ramenee a sa position VISIBLE via
; EDIT_WINDOW_ROW_OFF) - "XX " = 3 caracteres par cellule sur le LCD,
; DECALEE de EDIT_ADDR_LABEL_WIDTH (5) pour laisser la place a
; l'etiquette d'adresse "SSSS:" en tete de chaque ligne (voir
; edit_ram_draw_grid - EDIT_COLS a ete reduit a 5 precisement pour
; que ce total (5 + 5*3 = 20) ne deborde jamais la largeur du LCD).
; Sortie: AH = adresse DDRAM (0-127).
; ============================================================
edit_ram_cell_ddram:
        push    bx
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]                ; AX = position lineaire du curseur
        mov     cx, EDIT_COLS
        xor     dx, dx
        div     cx                      ; AX = ligne logique, DX = colonne (0-4)
        mov     bl, dl                  ; BL = colonne

        mov     bp, EDIT_WINDOW_ROW_OFF
        sub     ax, [bp]                ; AX = ligne VISIBLE (logique - fenetre)
        mov     bh, al                  ; BH = ligne visible (0-3)

        mov     al, bl
        mov     cl, 3
        mul     cl                      ; AX = colonne*3
        mov     cl, al                  ; CL = decalage colonne DANS LA GRILLE (0,3,...,12)

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
        add     al, EDIT_ADDR_LABEL_WIDTH ; decale par l'etiquette d'adresse ("SSSS:",
                                          ; 5 caracteres) en tete de chaque ligne LCD -
                                          ; voir edit_ram_draw_grid
        add     al, cl
        mov     ah, al                  ; AH = adresse DDRAM (sortie)

        pop     bp
        pop     dx
        pop     cx
        pop     bx
        ret

; ============================================================
; edit_ram_place_cursor
; Positionne le curseur materiel du LCD (actif, clignotant) sur la
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
; Ecrit DL DANS LE TAMPON (EDIT_BUFFER_OFF + EDIT_CURSOR_OFF) - jamais
; directement en RAM reelle (voir edit_ram_action, edit_ram_commit_buffer).
; Entree: DL = valeur a ecrire.
; ============================================================
edit_ram_write_current:
        push    ax
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]                ; AX = position lineaire du curseur
        mov     bp, EDIT_BUFFER_OFF
        add     bp, ax                  ; BP = pointeur tampon pour cette case
        mov     [bp], dl

        pop     bp
        pop     ax
        ret

; ============================================================
; edit_ram_scroll_to_cursor
; Ajuste EDIT_WINDOW_ROW_OFF pour que la ligne logique du curseur
; (EDIT_CURSOR_OFF) reste visible (entre la fenetre et fenetre+3) -
; fait defiler d'exactement ce qu'il faut, dans un sens ou l'autre.
; Appelee apres tout deplacement du curseur qui change de ligne
; logique (move_up/move_down/advance).
; ============================================================
edit_ram_scroll_to_cursor:
        push    ax
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        xor     dx, dx
        mov     cx, 6
        div     cx                      ; AX = ligne logique du curseur

        mov     bp, EDIT_WINDOW_ROW_OFF
        cmp     ax, [bp]
        jae     .check_bottom
        mov     [bp], ax                ; au-dessus de la fenetre - remonte
        jmp     .done
.check_bottom:
        mov     cx, [bp]
        add     cx, EDIT_ROWS - 1       ; CX = derniere ligne visible actuellement
        cmp     ax, cx
        jbe     .done                   ; toujours visible
        sub     ax, EDIT_ROWS
        inc     ax                      ; nouvelle fenetre = ligne - (EDIT_ROWS-1)
        mov     [bp], ax
.done:
        pop     bp
        pop     dx
        pop     cx
        pop     ax
        ret

; ============================================================
; edit_ram_move_left / _right
; Deplacent le curseur logique (EDIT_CURSOR_OFF) DANS SA LIGNE - fixe
; aux bords de colonne (pas de saut a la ligne suivante/precedente).
; ============================================================
edit_ram_move_left:
        push    ax
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        xor     dx, dx
        mov     cx, 6
        div     cx                      ; DX = colonne actuelle (0-5)
        cmp     dx, 0
        je      .done
        dec     word [bp]
.done:
        pop     bp
        pop     dx
        pop     cx
        pop     ax
        ret

edit_ram_move_right:
        push    ax
        push    bx
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        mov     bx, ax                  ; BX = curseur actuel (preserve - AX va
                                          ; etre ecrase par la division)
        xor     dx, dx
        mov     cx, 6
        div     cx                      ; DX = colonne actuelle (0-5)
        cmp     dx, EDIT_COLS-1
        jae     .done                   ; deja en derniere colonne

        inc     bx                      ; BX = candidat
        mov     bp, EDIT_SIZE_OFF
        cmp     bx, [bp]
        jae     .done                   ; deborderait la plage - ne bouge pas

        mov     bp, EDIT_CURSOR_OFF
        mov     [bp], bx
.done:
        pop     bp
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_move_up / _down
; Deplacent le curseur logique (EDIT_CURSOR_OFF) d'UNE LIGNE LOGIQUE -
; fixes aux bords de la plage (premiere/derniere ligne). Font defiler
; la fenetre visible au besoin (edit_ram_scroll_to_cursor) - c'est ce
; qui permet a la grille de couvrir toute la plage (jusqu'a 1024
; octets = 205 lignes), pas seulement les 4 premieres lignes visibles.
; ============================================================
edit_ram_move_up:
        push    ax
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        cmp     ax, EDIT_COLS
        jb      .done                   ; deja sur la premiere ligne logique
        sub     ax, EDIT_COLS
        mov     [bp], ax
        call    edit_ram_scroll_to_cursor
.done:
        pop     bp
        pop     ax
        ret

edit_ram_move_down:
        push    ax
        push    bx
        push    cx
        push    dx
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     bx, [bp]                ; BX = curseur actuel (preserve)

        ; --- une ligne SUIVANTE existe-t-elle seulement (meme
        ; partielle)? Sans cette verification, un "+6" qui deborde la
        ; plage retomberait sur le dernier octet valide MEME s'il est
        ; sur LA MEME ligne logique (aucune ligne en dessous) - bug
        ; trouve et corrige AVANT deploiement par trace manuelle (voir
        ; Directives.md): taille=4 (une seule ligne partielle) faisait
        ; sauter du debut a la fin de CETTE ligne au lieu de ne rien
        ; faire. ---
        mov     ax, bx
        xor     dx, dx
        mov     cx, 6
        div     cx                      ; AX = ligne logique courante (DX jete)
        inc     ax                      ; AX = ligne logique SUIVANTE
        mov     cx, 6
        mul     cx                      ; AX = 1er octet de cette ligne suivante
                                          ; (DX ecrase a 0 - le produit tient
                                          ; dans AX, max 171*6=1026)

        mov     bp, EDIT_SIZE_OFF
        mov     cx, [bp]                ; CX = taille totale
        cmp     ax, cx
        jae     .done                   ; aucune ligne suivante - fixe (pas de
                                          ; deplacement)

        ; --- il y a une ligne suivante: nouvelle position = curseur+6,
        ; ou le dernier octet valide si cette ligne est partielle et
        ; que la colonne courante n'y existe pas ---
        mov     ax, bx
        add     ax, EDIT_COLS
        cmp     ax, cx
        jb      .have_candidate
        mov     ax, cx
        dec     ax                      ; AX = dernier octet valide (taille-1)
.have_candidate:
        cmp     ax, bx
        je      .done                   ; aucun changement reel

        mov     bp, EDIT_CURSOR_OFF
        mov     [bp], ax
        call    edit_ram_scroll_to_cursor
.done:
        pop     bp
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_ram_advance
; Deplace le curseur logique (EDIT_CURSOR_OFF) a la case SUIVANTE en
; ordre de lecture (gauche a droite, puis ligne suivante) - appelee
; apres Entree pour passer automatiquement a l'octet suivant. Fixe a
; la derniere case de la plage (pas de retour au debut). Fait defiler
; la fenetre visible au besoin.
; ============================================================
edit_ram_advance:
        push    ax
        push    bp

        mov     bp, EDIT_CURSOR_OFF
        mov     ax, [bp]
        inc     ax
        mov     bp, EDIT_SIZE_OFF
        cmp     ax, [bp]
        jae     .done                   ; deja sur la derniere case - ne bouge pas

        mov     bp, EDIT_CURSOR_OFF
        mov     [bp], ax
        call    edit_ram_scroll_to_cursor
.done:
        pop     bp
        pop     ax
        ret

; ============================================================
; print_reg_hex_bin_uart
; Affiche AX en hexadecimal PUIS en binaire sur l'UART, separes par 2
; espaces ("HHHH  BBBBBBBBBBBBBBBB") - le libelle ("AX=" etc.) doit
; deja avoir ete affiche par l'appelant au prealable (voir
; registers_dump_action, qui utilise la macro "print" pour ca).
; Entree: AX = valeur a afficher.
; Detruit: AX, BX (voir uart_tx_hex_word/uart_tx_bin_word). Jamais
; CX/DX/SI/DI/ES/BP.
; ============================================================
print_reg_hex_bin_uart:
        push    ax                   ; uart_tx_hex_word DETRUIT AX - sauvegarde
                                      ; pour l'affichage binaire qui suit
        call    uart_tx_hex_word
        mov     al, ' '
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte
        pop     ax
        call    uart_tx_bin_word
        ret

; ============================================================
; registers_dump_action
; Option "3) Registres CPU" du sous-menu Dump memory (voir
; .dump_menu, start:): affiche l'etat courant des registres du 8088
; (AX,BX,CX,DX,SI,DI,BP,SP,CS,DS,ES,SS,IP,FLAGS) sur le LCD (pagine
; sur 2 ecrans - 14 valeurs, trop pour les 4x20 caracteres
; disponibles d'un coup) et sur l'UART (tout d'un coup, format
; "ergonomique" inspire de DEBUG.COM - le debogueur DOS classique -
; avec decodage complet des FLAGS, demande explicitement).
;
; CAPTURE: tout est fige des l'entree, AVANT le moindre usage de
; AX/BX/CX/DX/SI/DI comme registre de travail pour l'affichage -
; chaque registre est empile, puis relu ensuite via [bp+/-N] (SS par
; defaut sur le 8086 pour cette forme d'adressage - meme motif que
; int16h_handler/.set_flags, qui utilise deja "mov bp,sp" pour
; adresser la pile directement). Details de chaque valeur:
;
;   IP affiche = ADRESSE DE RETOUR, deja empilee par le CALL qui a
;   mene ici (voir [bp+2] ci-dessous) - la valeur exacte a laquelle
;   l'execution reprendra une fois cette action terminee, equivalent
;   exact de ce qu'un debogueur montrerait a un point d'arret place
;   juste apres ce CALL.
;
;   SP affiche = SP tel que vu par l'APPELANT, avant ce CALL (donc
;   avant que CALL n'empile IP et avant notre propre "push bp") -
;   simple calcul BP+4, jamais relu depuis la pile (rien n'est
;   empile "pour" cette valeur - c'est la position de BP elle-meme,
;   decalee, qui la represente).
;
;   CS/DS/ES/SS/FLAGS: empiles uniquement pour pouvoir les LIRE (le
;   8086 n'a pas de "MOV reg,FLAGS" ni de "MOV reg,CS" utilisable
;   pour ecrire ailleurs qu'empiler - PUSHF/PUSH CS etc. restent la
;   seule facon). Ces 5 mots ne sont PAS remis dans un registre au
;   retour (voir .done: "add sp,10") puisque cette routine ne les a
;   jamais reellement MODIFIES - seulement empiles comme donnee.
;
; Navigation (comme edit_ram_action): fleches Gauche/Droite pour
; changer de page LCD (1/2, avec retour a la page 1 depuis la page
; 2), Echap pour revenir au sous-menu Dump memory. Toute autre touche
; est ignoree (pas de redessin inutile - rien ne change tant que la
; page ne change pas). L'UART, lui, affiche tout en une seule fois
; des l'entree (un flux serie n'a pas de largeur limitee comme le
; LCD).
; ============================================================
registers_dump_action:
        push    bp
        mov     bp, sp                   ; [bp+0]=BP original, [bp+2]=IP de retour
                                          ; (empile par le CALL qui a mene ici)

        ; --- registres "segment/flags" - jamais modifies par cette
        ; routine, empiles seulement pour pouvoir les afficher (voir
        ; .done: liberes sans etre repop-es dans un registre) ---
        pushf                            ; [bp-2]  = FLAGS
        push    ss                       ; [bp-4]  = SS
        push    es                       ; [bp-6]  = ES
        push    ds                       ; [bp-8]  = DS
        push    cs                       ; [bp-10] = CS

        ; --- registres "generaux" - utilises comme scratch plus bas
        ; pour composer l'affichage, donc DOIVENT etre restaures
        ; avant le retour (voir .done) ---
        push    ax                       ; [bp-12] = AX
        push    bx                       ; [bp-14] = BX
        push    cx                       ; [bp-16] = CX
        push    dx                       ; [bp-18] = DX
        push    si                       ; [bp-20] = SI
        push    di                       ; [bp-22] = DI

        call    lcd_init                 ; ecran LCD propre pour cet affichage

        ; ---------------------------------------------------------
        ; UART: chaque registre affiche en HEXADECIMAL PUIS EN
        ; BINAIRE ("AX=HHHH  BBBBBBBBBBBBBBBB"), 2 registres par
        ; ligne (voir print_reg_hex_bin_uart). FLAGS a part, sur SA
        ; PROPRE ligne (hexa + binaire + mnemoniques), apres une ligne
        ; vide de separation - voir txt_reg_*/txt_flag_*_set/clear,
        ; section donnees.
        ; ---------------------------------------------------------
        print   txt_reg_banniere, UART

        print   txt_reg_ax, UART
        mov     ax, [bp-12]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_bx, UART
        mov     ax, [bp-14]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_cx, UART
        mov     ax, [bp-16]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_dx, UART
        mov     ax, [bp-18]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_si, UART
        mov     ax, [bp-20]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_di, UART
        mov     ax, [bp-22]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_sp, UART
        mov     ax, bp
        add     ax, 4                    ; SP vu par l'appelant (voir en-tete)
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_bp, UART
        mov     ax, [bp+0]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ds, UART
        mov     ax, [bp-8]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_es, UART
        mov     ax, [bp-6]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ss, UART
        mov     ax, [bp-4]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_cs, UART
        mov     ax, [bp-10]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ip, UART
        mov     ax, [bp+2]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART
        print   txt_crlf, UART          ; ligne vide avant FLAGS (voir en-tete)

        ; --- FLAGS SEUL sur sa ligne: hexa, binaire, PUIS mnemoniques
        ; (ordre DEBUG.COM: OF DF IF SF ZF AF PF CF) - DX charge UNE
        ; FOIS pour les 8 invocations de uart_flag_bit (voir sa
        ; definition, section macros) ---
        print   txt_reg_flags_prefix, UART
        mov     ax, [bp-2]
        call    print_reg_hex_bin_uart
        print   txt_reg_flags_sep, UART

        mov     dx, [bp-2]
        uart_flag_bit 0800h, txt_flag_of_set, txt_flag_of_clear
        uart_flag_bit 0400h, txt_flag_df_set, txt_flag_df_clear
        uart_flag_bit 0200h, txt_flag_if_set, txt_flag_if_clear
        uart_flag_bit 0080h, txt_flag_sf_set, txt_flag_sf_clear
        uart_flag_bit 0040h, txt_flag_zf_set, txt_flag_zf_clear
        uart_flag_bit 0010h, txt_flag_af_set, txt_flag_af_clear
        uart_flag_bit 0004h, txt_flag_pf_set, txt_flag_pf_clear
        uart_flag_bit 0001h, txt_flag_cf_set, txt_flag_cf_clear
        print   txt_crlf, UART
        print   txt_crlf, UART

        ; ---------------------------------------------------------
        ; LCD: pagine sur 2 ecrans (voir en-tete) - SI=0 -> page 1
        ; (AX/BX/CX/DX/SI/DI/SP/BP), SI=1 -> page 2 (CS/DS/ES/SS/IP/
        ; FLAGS, decodees en toutes lettres sur la ligne 4). Le
        ; numero de page vit dans SI plutot que DX: .draw_page2
        ; recharge DX avec la valeur de FLAGS pour son decodage en
        ; lettres (voir plus bas, "mov dx,[bp-2]"), ce qui ecraserait
        ; un numero de page qui y aurait ete range - SI, lui, n'est
        ; JAMAIS touche par gotoxy/print/lcd_tx_hex_word/lcd_data/
        ; ps2_get_char (tous le preservent - voir leurs en-tetes
        ; respectifs), donc stable sur tout ce sous-flux. La valeur
        ; ORIGINALE de SI (celle de l'appelant) a deja ete affichee
        ; plus haut (UART) et relue depuis [bp-20] - SI est donc
        ; libre ici pour servir de simple numero de page.
        ; ---------------------------------------------------------
        xor     si, si                   ; page courante = 0 (page 1)

.redraw:
        cmp     si, 0
        je      .draw_page1
        jmp     .draw_page2

.draw_page1:
        gotoxy  0, 0, LCD
        print   txt_lcd_reg_ax, LCD
        mov     ax, [bp-12]
        call    lcd_tx_hex_word
        gotoxy  0, 9, LCD
        print   txt_lcd_reg_bx, LCD
        mov     ax, [bp-14]
        call    lcd_tx_hex_word
        gotoxy  0, 17, LCD
        print   txt_lcd_page1, LCD

        gotoxy  1, 0, LCD
        print   txt_lcd_reg_cx, LCD
        mov     ax, [bp-16]
        call    lcd_tx_hex_word
        gotoxy  1, 9, LCD
        print   txt_lcd_reg_dx, LCD
        mov     ax, [bp-18]
        call    lcd_tx_hex_word

        gotoxy  2, 0, LCD
        print   txt_lcd_reg_si, LCD
        mov     ax, [bp-20]
        call    lcd_tx_hex_word
        gotoxy  2, 9, LCD
        print   txt_lcd_reg_di, LCD
        mov     ax, [bp-22]
        call    lcd_tx_hex_word

        gotoxy  3, 0, LCD
        print   txt_lcd_reg_sp, LCD
        mov     ax, bp
        add     ax, 4                    ; SP vu par l'appelant (voir en-tete)
        call    lcd_tx_hex_word
        gotoxy  3, 9, LCD
        print   txt_lcd_reg_bp, LCD
        mov     ax, [bp+0]
        call    lcd_tx_hex_word
        jmp     .wait_key

.draw_page2:
        gotoxy  0, 0, LCD
        print   txt_lcd_reg_cs, LCD
        mov     ax, [bp-10]
        call    lcd_tx_hex_word
        gotoxy  0, 9, LCD
        print   txt_lcd_reg_ip, LCD
        mov     ax, [bp+2]
        call    lcd_tx_hex_word
        gotoxy  0, 17, LCD
        print   txt_lcd_page2, LCD

        gotoxy  1, 0, LCD
        print   txt_lcd_reg_ds, LCD
        mov     ax, [bp-8]
        call    lcd_tx_hex_word
        gotoxy  1, 9, LCD
        print   txt_lcd_reg_es, LCD
        mov     ax, [bp-6]
        call    lcd_tx_hex_word

        gotoxy  2, 0, LCD
        print   txt_lcd_reg_ss, LCD
        mov     ax, [bp-4]
        call    lcd_tx_hex_word
        gotoxy  2, 9, LCD
        print   txt_lcd_reg_fl, LCD
        mov     ax, [bp-2]
        call    lcd_tx_hex_word

        ; --- ligne 4: FLAGS decodees en 8 lettres (meme ordre que
        ; l'UART: O D I S Z A P C = OF DF IF SF ZF AF PF CF) -
        ; MAJUSCULE si le bit est a 1, minuscule si a 0 (+20h, motif
        ; standard ASCII maj->min). "lcd_goto" (PAS "gotoxy"): ecrit
        ; directement au LCD sans passer par int10h (aucun "print" de
        ; chaine ici, seulement des lcd_data au fil de l'eau - voir
        ; l'en-tete de int10h_print_string: "gotoxy" seul, sans
        ; "print" a la suite, NE deplace PAS le curseur PHYSIQUE, donc
        ; ne convient pas ici). Complete a 20 caracteres (5 espaces de
        ; remplissage finaux) pour ecraser tout residu de la page 1
        ; (ligne 4 plus courte, "SP=xxxx  BP=xxxx" = 16 caracteres). ---
        lcd_goto LCD_LINE4
        mov     dx, [bp-2]               ; DX = FLAGS (relit depuis la pile - le "DX
                                          ; page" servait seulement a choisir cette
                                          ; branche, plus besoin maintenant)

        mov     al, 'O'
        test    dx, 0800h
        jnz     .p2_of
        add     al, 20h
.p2_of: call    lcd_data
        mov     al, ' '
        call    lcd_data

        mov     al, 'D'
        test    dx, 0400h
        jnz     .p2_df
        add     al, 20h
.p2_df: call    lcd_data
        mov     al, ' '
        call    lcd_data

        mov     al, 'I'
        test    dx, 0200h
        jnz     .p2_if
        add     al, 20h
.p2_if: call    lcd_data
        mov     al, ' '
        call    lcd_data

        mov     al, 'S'
        test    dx, 0080h
        jnz     .p2_sf
        add     al, 20h
.p2_sf: call    lcd_data
        mov     al, ' '
        call    lcd_data

        mov     al, 'Z'
        test    dx, 0040h
        jnz     .p2_zf
        add     al, 20h
.p2_zf: call    lcd_data
        mov     al, ' '
        call    lcd_data

        mov     al, 'A'
        test    dx, 0010h
        jnz     .p2_af
        add     al, 20h
.p2_af: call    lcd_data
        mov     al, ' '
        call    lcd_data

        mov     al, 'P'
        test    dx, 0004h
        jnz     .p2_pf
        add     al, 20h
.p2_pf: call    lcd_data
        mov     al, ' '
        call    lcd_data

        mov     al, 'C'
        test    dx, 0001h
        jnz     .p2_cf
        add     al, 20h
.p2_cf: call    lcd_data

        mov     cx, 5                    ; 5 espaces de remplissage finaux (voir
.p2_pad:                                 ; commentaire ci-dessus - 15+5=20)
        mov     al, ' '
        call    lcd_data
        loop    .p2_pad

.wait_key:
        call    ps2_get_char

        cmp     al, 27                   ; Echap: retour au sous-menu Dump memory
        je      .done

        cmp     al, PS2_KEY_LEFT
        je      .toggle_page
        cmp     al, PS2_KEY_RIGHT
        je      .toggle_page
        jmp     .wait_key                ; touche non pertinente - ignoree, rien
                                          ; n'a change, pas besoin de redessiner

.toggle_page:
        xor     si, 1                    ; bascule 0<->1 (page 1 <-> page 2)
        jmp     .redraw

.done:
        ; --- IMPORTANT: restaurer AX/BX/CX/DX/SI/DI (empiles APRES
        ; FLAGS/SS/ES/DS/CS, donc au sommet de la pile en ce point -
        ; voir l'entree de cette routine) AVANT de liberer l'espace de
        ; FLAGS/SS/ES/DS/CS avec "add sp,10": faire l'inverse (add sp
        ; puis pop) depilerait les MAUVAISES valeurs dans AX..DI. ---
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        add     sp, 10                   ; libere FLAGS/SS/ES/DS/CS (5 mots, jamais
                                          ; modifies par cette routine - rien a
                                          ; restaurer, juste liberer la pile)
        pop     bp
        ret

; ============================================================
; edit_run_action
; Option "4) Edit+Run RAM" du sous-menu Dump memory (voir .dump_menu,
; start:): edite la RAM a une adresse FIXE, 1000:0000 (deuxieme bloc
; de 64K, oppose au segment 0000h de edit_ram_action), et permet
; d'EXECUTER le code qui y a ete saisi via la touche 'r'/'R'.
;
; Reutilise TOUT l'appareil de edit_ram_action (grille, defilement,
; tampon - edit_ram_draw_grid/cell_ddram/place_cursor/write_current/
; scroll_to_cursor/move_left/right/up/down/advance sont agnostiques du
; segment: ils ne touchent jamais a la "vraie" RAM, seulement au
; tampon EDIT_BUFFER_OFF - voir leurs en-tetes), sauf pour charger/
; valider le tampon vers la vraie RAM (edit_run_load_buffer/
; commit_buffer, segment 1000h) et pour la composition d'un octet
; (edit_run_byte_value au lieu de ps2_edit_byte_value - voir plus bas,
; necessaire pour reconnaitre 'r'/'R' PENDANT la saisie).
;
; AUCUNE SAISIE (demande explicite - accelere les tests): l'adresse de
; depart est TOUJOURS 0000h (donc 1000:0000) et la TAILLE est TOUJOURS
; EDIT_RUN_SIZE (255 octets, largement sous la zone reservee
; 0F800h-0FFFFh et sous la pile active SS=1000h) - toutes deux fixees
; directement dans EDIT_BASE_OFF/EDIT_SIZE_OFF, sans aucun prompt: la
; grille s'affiche immediatement.
;
; Touches (identiques a edit_ram_action, PLUS 'r'/'R'):
;   Echap - ANNULE toute l'edition (tampon abandonne), retour au menu.
;   Q/q   - VALIDE (tampon -> RAM reelle a 1000:0000), SANS executer,
;           retour au menu.
;   R/r   - VALIDE (comme Q/q), PUIS EXECUTE le code a 1000:0000 (voir
;           edit_run_execute_and_show) et affiche les registres sur
;           l'UART, puis retour au menu. RECONNUE A TOUT MOMENT, meme
;           AU MILIEU de la composition d'un octet (voir
;           edit_run_byte_value) - dans ce cas, le chiffre partiel non
;           encore valide est ABANDONNE (rien n'est ecrit pour cette
;           case).
;   Chiffre hexa - comme edit_ram_action, SAUF qu'Entree n'est PLUS
;           NECESSAIRE pour valider un octet COMPLET: le 2e chiffre
;           hexa valide et avance AUTOMATIQUEMENT (Entree reste
;           disponible pour valider un octet d'UN SEUL chiffre).
;   (fleches: voir edit_ram_action)
; ============================================================
edit_run_action:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        call    lcd_init

        ; --- adresse/taille FIXES (0000h/255) - aucune saisie (voir
        ; en-tete) ---
        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_BASE_OFF
        mov     word [es:di], 0
        mov     di, EDIT_SIZE_OFF
        mov     word [es:di], EDIT_RUN_SIZE

        print   txt_run_address, UART
        print   txt_run_help, UART

        call    edit_run_load_buffer            ; copie 1000:0000.. (RAM reelle) -> tampon

        mov     ax, VAR_SEG
        mov     es, ax
        mov     di, EDIT_CURSOR_OFF
        mov     word [es:di], 0
        mov     di, EDIT_WINDOW_ROW_OFF
        mov     word [es:di], 0

.redraw:
        call    edit_ram_draw_grid

.wait_key:
        call    ps2_get_char

        cmp     al, 27                          ; Echap: annule (rien recopie)
        je      .done

        cmp     al, 'q'
        je      .commit_only
        cmp     al, 'Q'
        je      .commit_only

        cmp     al, 'r'
        je      .commit_and_run
        cmp     al, 'R'
        je      .commit_and_run

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
        mov     dl, al                   ; DL = touche deja lue (sauvegardee -
                                          ; edit_ram_cell_ddram detruit AX)
        call    edit_ram_cell_ddram      ; AH = adresse DDRAM de la case courante
        mov     al, dl                   ; restaure AL = touche (AH inchange)
        call    edit_run_byte_value      ; AL(entree)=touche deja lue; DL/CF = sortie (voir en-tete plus bas)
        jc      .redraw                  ; Entree sans saisie (DL=0 dans ce cas) - rien a ecrire.
                                          ; VERIFIE AVANT "cmp dl,1": ce dernier ECRASERAIT le CF
                                          ; de sortie d'edit_run_byte_value (0-1 = emprunt = CF=1
                                          ; meme quand DL=0 signifiait "valeur prete", CF=0) - bug
                                          ; trouve sur le materiel reel (2e chiffre "avale" une
                                          ; case qui restait a 00), corrige en testant jc EN PREMIER.
        cmp     dl, 1
        je      .commit_and_run          ; 'r'/'R' tapee PENDANT la saisie - execute immediatement
        mov     dl, bl                   ; DL = valeur a ecrire (survit a l'appel)
        call    edit_ram_write_current   ; ecrit DANS LE TAMPON
        call    edit_ram_advance         ; passe a la case suivante (ordre de lecture)
        jmp     .redraw

.commit_only:
        call    edit_run_commit_buffer          ; recopie le tampon -> RAM reelle (1000:0000)
        jmp     .done

.commit_and_run:
        call    edit_run_commit_buffer          ; recopie le tampon -> RAM reelle (1000:0000)
        call    edit_run_execute_and_show       ; execute et affiche les registres (UART)

.done:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; edit_run_byte_value
; Variante de ps2_edit_byte_value (lib/ps2.asm, INCHANGEE - reste
; utilisee par edit_ram_action) POUR edit_run_action uniquement: cette
; derniere BOUCLE INTERNEMENT sur ps2_get_char jusqu'a Entree (touche
; par touche, jamais rendue a l'appelant avant), ce qui AVALERAIT
; SILENCIEUSEMENT 'r'/'R' s'il etait tape APRES un premier chiffre (la
; boucle .wait_key exterieure d'edit_run_action, qui le reconnait,
; elle, ne serait jamais re-atteinte). Cette variante ajoute donc:
;   1) 'r'/'R' reconnue A CHAQUE touche lue (avant meme le premier
;      chiffre) - retour immediat, chiffre(s) partiel(s) ABANDONNES.
;   2) Validation AUTOMATIQUE apres le 2e chiffre hexa - Entree n'est
;      plus NECESSAIRE pour un octet complet (elle reste disponible
;      pour valider un octet d'UN SEUL chiffre, comme avant).
;
; Entree: AL = premier caractere deja lu par l'appelant (edit_ram_cell_
;         ddram y a ete appele juste avant - AH = adresse DDRAM de la
;         cellule, inchange par cette routine).
; Sortie: BX = valeur composee (uniquement si DL=0 et CF=0).
;         DL=0, CF=0: au moins un chiffre tape - valeur (BX) a ecrire.
;         DL=0, CF=1: Entree pressee sans aucune saisie - rien a
;                      ecrire (comme ps2_edit_byte_value).
;         DL=1: 'r'/'R' pressee (a tout moment) - BX indefini, rien a
;               ecrire, l'appelant doit executer immediatement (voir
;               edit_run_action, .commit_and_run).
; Detruit: AX, CX, DX (BX/DL = sortie). Jamais SI/DI/ES/BP.
; ============================================================
edit_run_byte_value:
        push    si              ; SI = accumulateur interne (voir
                                 ; ps2_edit_byte_value - meme raison)
        xor     si, si
        xor     dh, dh          ; DH = nombre de chiffres saisis (0-2)
        jmp     .have_key       ; traite d'abord le caractere deja lu

.next_key:
        call    ps2_get_char
.have_key:
        cmp     al, 'r'         ; 'r'/'R': interrompt A TOUT MOMENT (voir
        je      .interrupt_run  ; en-tete) - verifie AVANT toute autre
        cmp     al, 'R'         ; interpretation du caractere
        je      .interrupt_run

        cmp     al, 13          ; Entree ?
        je      .commit
        cmp     al, 8           ; retour arriere ?
        je      .backspace
        call    ps2_hex_digit_value
        jc      .next_key       ; touche non geree - ignore
        cmp     dh, 2
        jae     .next_key       ; deja 2 chiffres - ignore
        mov     dl, al
        mov     cl, 4
        shl     si, cl
        push    dx              ; DH(compteur)/DL(valeur) sauvegardes ensemble
        mov     dh, 0
        add     si, dx
        pop     dx
        mov     al, dl
        call    uart_tx_hex_nibble
        mov     al, dl
        call    lcd_tx_hex_nibble
        inc     dh
        cmp     dh, 2
        jb      .next_key
        jmp     .commit          ; 2e chiffre: valide AUTOMATIQUEMENT (voir en-tete)

.backspace:
        cmp     dh, 0
        je      .next_key
        dec     dh
        mov     cl, 4
        shr     si, cl
        mov     al, 8
        call    uart_tx_byte
        mov     al, ' '
        call    uart_tx_byte
        mov     al, 8
        call    uart_tx_byte
        mov     al, ah
        add     al, dh
        or      al, 80h
        call    lcd_command
        mov     al, ' '
        call    lcd_data
        mov     al, ah
        add     al, dh
        or      al, 80h
        call    lcd_command
        jmp     .next_key

.commit:
        cmp     dh, 0
        je      .empty
        mov     bx, si          ; BX = valeur finale (sortie documentee)
        mov     dl, 0
        pop     si
        clc
        ret
.empty:
        mov     dl, 0
        pop     si
        stc
        ret
.interrupt_run:
        mov     dl, 1
        pop     si
        clc
        ret

; ============================================================
; edit_run_execute_and_show
; Execute le code injecte par edit_run_action a l'adresse FIXE
; 1000:0000 via un CALL FAR IMMEDIAT (opcode 9A, encode directement
; par NASM pour "call seg:off" avec des constantes) - le code injecte
; DOIT se terminer par RETF (retour LOINTAIN, depile IP ET CS),
; JAMAIS un RET pres: un RET pres ne depilerait que IP et laisserait
; CS empile, corrompant la pile et faisant planter la carte au retour
; (voir README.md pour la regle destinee au programmeur du code
; injecte).
;
; CAPTURE: CALL/RETF ne modifient JAMAIS un registre general ni
; FLAGS - seulement CS:IP (et implicitement SP, via les push/pop
; internes de l'instruction elle-meme). Donc, immediatement apres le
; retour du CALL FAR, TOUT registre est EXACTEMENT ce que le code
; injecte a laisse - a condition de ne rien faire d'autre qu'empiler
; (jamais de MOV/ADD/etc. qui le detruirait) avant de les avoir tous
; sauvegardes. Meme motif que registers_dump_action (voir plus haut),
; mais SANS le decalage du "CALL qui a mene ici": ici, un seul mot
; ("push bp") est empile avant "mov bp,sp", donc:
;   [bp+0] = BP (tel que laisse par le code injecte)
;   bp+2   = SP (tel que laisse par le code injecte, PAS relu depuis
;            la pile - simple calcul, comme "bp+4" dans
;            registers_dump_action, mais avec un seul mot de decalage
;            ici au lieu de deux puisqu'il n'y a pas de "CALL" externe
;            a comptabiliser)
;
; ATTENTION: si le code injecte modifie SS sans le restaurer, les
; push/pop de CETTE routine (qui s'executent APRES son retour)
; cibleraient une pile invalide - risque inherent a l'execution de
; code arbitraire, comme la commande "G" de DEBUG.COM.
;
; Affiche UNIQUEMENT sur l'UART (demande explicite - pas de LCD pour
; cet affichage): AX/BX/CX/DX/SI/DI/SP/BP/DS/ES/SS/CS en hexadecimal
; et binaire (2 registres par ligne, voir print_reg_hex_bin_uart),
; puis FLAGS sur sa propre ligne (hexa + binaire + mnemoniques,
; reutilise txt_reg_*/txt_flag_*_set/clear/uart_flag_bit - voir
; registers_dump_action). IP non affiche (aucune signification utile
; ici, contrairement a registers_dump_action).
; ============================================================
edit_run_execute_and_show:
        call    1000h:0000h              ; CALL FAR - le code injecte doit finir par RETF

        push    bp
        mov     bp, sp                   ; [bp+0] = BP (code injecte); bp+2 = SP (code injecte)

        pushf                            ; [bp-2]  = FLAGS
        push    ss                       ; [bp-4]  = SS
        push    es                       ; [bp-6]  = ES
        push    ds                       ; [bp-8]  = DS
        push    cs                       ; [bp-10] = CS
        push    ax                       ; [bp-12] = AX
        push    bx                       ; [bp-14] = BX
        push    cx                       ; [bp-16] = CX
        push    dx                       ; [bp-18] = DX
        push    si                       ; [bp-20] = SI
        push    di                       ; [bp-22] = DI

        print   txt_run_result_banner, UART

        print   txt_reg_ax, UART
        mov     ax, [bp-12]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_bx, UART
        mov     ax, [bp-14]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_cx, UART
        mov     ax, [bp-16]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_dx, UART
        mov     ax, [bp-18]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_si, UART
        mov     ax, [bp-20]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_di, UART
        mov     ax, [bp-22]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_sp, UART
        mov     ax, bp
        add     ax, 2                    ; SP tel que laisse par le code injecte (voir en-tete)
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_bp, UART
        mov     ax, [bp+0]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ds, UART
        mov     ax, [bp-8]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_es, UART
        mov     ax, [bp-6]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART

        print   txt_reg_ss, UART
        mov     ax, [bp-4]
        call    print_reg_hex_bin_uart
        print   txt_reg_pair_sep, UART
        print   txt_reg_cs, UART
        mov     ax, [bp-10]
        call    print_reg_hex_bin_uart
        print   txt_crlf, UART
        print   txt_crlf, UART           ; ligne vide avant FLAGS

        print   txt_reg_flags_prefix, UART
        mov     ax, [bp-2]
        call    print_reg_hex_bin_uart
        print   txt_reg_flags_sep, UART

        mov     dx, [bp-2]
        uart_flag_bit 0800h, txt_flag_of_set, txt_flag_of_clear
        uart_flag_bit 0400h, txt_flag_df_set, txt_flag_df_clear
        uart_flag_bit 0200h, txt_flag_if_set, txt_flag_if_clear
        uart_flag_bit 0080h, txt_flag_sf_set, txt_flag_sf_clear
        uart_flag_bit 0040h, txt_flag_zf_set, txt_flag_zf_clear
        uart_flag_bit 0010h, txt_flag_af_set, txt_flag_af_clear
        uart_flag_bit 0004h, txt_flag_pf_set, txt_flag_pf_clear
        uart_flag_bit 0001h, txt_flag_cf_set, txt_flag_cf_clear
        print   txt_crlf, UART
        print   txt_crlf, UART

        ; --- restaure AX/BX/CX/DX/SI/DI (registres "generaux" de
        ; CETTE routine - ils ne l'etaient plus depuis les push
        ; ci-dessus) AVANT de liberer FLAGS/SS/ES/DS/CS (5 mots,
        ; jamais modifies, juste empiles pour lecture) - meme ordre
        ; que registers_dump_action.done ---
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        add     sp, 10
        pop     bp
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
        print   txt_banniere1, UART
        print   txt_banniere2, UART
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
        cmp     bp, 0
        je      .lcd_ok
        gotoxy  2, 0, LCD
        print   lcd_txt_etat_defaut, LCD
        jmp     .lcd_etat_fin
.lcd_ok:
        gotoxy  2, 0, LCD
        print   lcd_txt_etat_ok, LCD
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
        print   txt_ram_ok, UART
        ret

msg_ram_defectueuse:
        print   txt_ram_defaut, UART
        ret

; ============================================================
; msg_dump_fin
; ============================================================
msg_dump_fin:
        print   txt_dump_fin, UART
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
; init_ivt_not_implemented
; Peuple les 256 entrees de l'IVT (INT 00h-FFh, segment 0000h) avec
; int_not_implemented (voir plus bas) - AVANT nos propres vecteurs
; (setup_bios_interrupts remplace ensuite les entrees INT 10h/16h
; uniquement). Elimine tout "garbage" residuel dans l'IVT (visible via
; Dump memory) et donne un diagnostic clair sur l'UART si du code
; appelle par erreur une interruption non geree. Appelee une seule
; fois au demarrage (voir start:).
; ============================================================
init_ivt_not_implemented:
        push    ax
        push    cx
        push    di
        push    es

        xor     ax, ax
        mov     es, ax                  ; ES = 0000h (IVT)
        xor     di, di
        mov     cx, 100h                ; 256 entrees
.next_entry:
        mov     word [es:di], int_not_implemented
        mov     word [es:di+2], cs
        add     di, 4
        loop    .next_entry

        pop     es
        pop     di
        pop     cx
        pop     ax
        ret

; ============================================================
; int_not_implemented
; Gestionnaire generique installe par defaut a TOUTES les entrees de
; l'IVT (voir init_ivt_not_implemented ci-dessus) - affiche un message
; sur l'UART et retourne (IRET). Remplace par un gestionnaire
; specifique pour INT 10h/16h (voir setup_bios_interrupts plus bas).
; Appel direct a uart_tx_string (pas la macro "print", qui passe par
; INT 10h) - ce gestionnaire doit rester independant de tout ce qui
; pourrait lui-meme etre en cause si une interruption inattendue
; survient.
; ============================================================
int_not_implemented:
        push    ax
        push    si
        mov     si, txt_int_non_implementee
        call    uart_tx_string
        pop     si
        pop     ax
        iret

; ============================================================
; setup_bios_interrupts
; Peuple l'IVT (segment 0000h, RAM) pour INT 10h (affichage) et
; INT 16h (clavier) - chaque entree est un pointeur FAR (offset puis
; segment, 4 octets, a l'adresse INT_NUM*4) vers int10h_handler/
; int16h_handler ci-dessous. Initialise aussi les curseurs logiques
; "esprit BIOS" (un jeu par device LCD/LCD I2C - voir
; BIOS_CURSOR_LCD_*/BIOS_CURSOR_LCDI2C_*, hardware.inc) a (0,0).
; Appelee une seule fois au demarrage (voir start:), avant toute
; utilisation de INT 10h/16h.
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
        mov     di, BIOS_CURSOR_LCD_ROW_OFF
        mov     byte [es:di], 0
        mov     di, BIOS_CURSOR_LCD_COL_OFF
        mov     byte [es:di], 0
        mov     di, BIOS_CURSOR_LCDI2C_ROW_OFF
        mov     byte [es:di], 0
        mov     di, BIOS_CURSOR_LCDI2C_COL_OFF
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
; adapte a ce materiel (2 LCD HD44780 4x20 + UART - pas de memoire
; video ni de VGA). Voir aussi les macros gotoxy/print
; (include/lcd_macros.inc), qui sont la facon normale d'utiliser cette
; interface plutot que de preparer les registres et faire "int 10h"
; a la main.
;
;   AH=02h - Positionne le curseur LOGIQUE du device BH (persiste en
;            RAM - voir BIOS_CURSOR_LCD_*/BIOS_CURSOR_LCDI2C_*,
;            hardware.inc): DH=ligne (0-3), DL=colonne (0-19). UN JEU
;            DE CURSEUR PAR DEVICE (LCD parallele et LCD I2C
;            n'interferent pas l'un avec l'autre). Aucune verification
;            de bornes. BH=UART (3, ou toute autre valeur que 1/2):
;            no-op (un flux serie n'a pas de position).
;
;   AH=09h - Ecrit AL au curseur logique courant DU DEVICE BH, CX fois
;            de suite (remplit CX cellules CONSECUTIVES a partir de
;            cette position pour LCD/LCD I2C - meme convention que le
;            vrai BIOS IBM PC, PAS "le meme caractere CX fois au meme
;            endroit"; pour UART, transmet simplement AL, CX fois de
;            suite, sans notion de position). Le debordement d'une
;            ligne LCD de 20 suit l'auto-increment materiel du HD44780
;            (adressage DDRAM entrelace des afficheurs 4 lignes
;            "type A" - LCD_LINE3/4 suivent directement LCD_LINE1/2 en
;            memoire interne) et peut deborder sur une AUTRE ligne
;            visible - pas d'ecretage logiciel. Registres:
;              BH = peripherique cible: 1 = LCD parallele,
;                   2 = LCD I2C (PCF8574), 3 = UART - toute autre
;                   valeur est ignoree (aucun affichage). Voir
;                   LCD/LCDI2C/UART (include/lcd_macros.inc).
;              BL = couleur - actuellement SANS EFFET (reservee pour
;                   une prochaine version: sortie couleur via codes
;                   ANSI sur l'UART - voir Directives.md).
;              CX = nombre de repetitions (0 = aucun effet).
;            Le curseur logique (LCD/LCD I2C) N'EST PAS deplace par
;            cet appel (meme comportement que le vrai BIOS AH=09h) -
;            un appel ulterieur a AH=02h est necessaire pour ecrire
;            ailleurs.
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
        cmp     bh, 1
        je      .cursor_lcd
        cmp     bh, 2
        je      .cursor_lcdi2c
        jmp     .done                            ; UART (ou non reconnu): pas de curseur
.cursor_lcd:
        mov     di, BIOS_CURSOR_LCD_ROW_OFF
        mov     [es:di], dh
        mov     di, BIOS_CURSOR_LCD_COL_OFF
        mov     [es:di], dl
        jmp     .done
.cursor_lcdi2c:
        mov     di, BIOS_CURSOR_LCDI2C_ROW_OFF
        mov     [es:di], dh
        mov     di, BIOS_CURSOR_LCDI2C_COL_OFF
        mov     [es:di], dl
        jmp     .done

.write_char:
        cmp     cx, 0
        je      .done                            ; rien a ecrire

        cmp     bh, 3
        je      .dev_uart                        ; UART: pas de curseur - transmet direct

        mov     bp, ax                           ; BP = caractere original (AL) -
                                                   ; AX va servir de scratch pour
                                                   ; acceder a VAR_SEG
        mov     ax, VAR_SEG
        mov     es, ax
        cmp     bh, 1
        je      .load_lcd
        cmp     bh, 2
        je      .load_lcdi2c
        jmp     .done                            ; peripherique non reconnu - ignore

.load_lcd:
        mov     di, BIOS_CURSOR_LCD_ROW_OFF
        mov     dh, [es:di]                      ; DH = ligne
        mov     di, BIOS_CURSOR_LCD_COL_OFF
        mov     dl, [es:di]                      ; DL = colonne
        call    bios_cursor_ddram                ; AH = adresse DDRAM (DH/DL consommes)
        mov     al, ah
        or      al, 80h                          ; AL = commande "Set DDRAM Address"
        call    lcd_command                      ; positionne le curseur materiel
        mov     ax, bp                           ; restaure AL = caractere
.dev_lcd_loop:
        call    lcd_data
        loop    .dev_lcd_loop
        jmp     .done

.load_lcdi2c:
        mov     di, BIOS_CURSOR_LCDI2C_ROW_OFF
        mov     dh, [es:di]
        mov     di, BIOS_CURSOR_LCDI2C_COL_OFF
        mov     dl, [es:di]
        call    bios_cursor_ddram                ; AH = adresse DDRAM (DH/DL consommes)
        mov     al, ah
        or      al, 80h
        call    i2c_lcd_command                  ; positionne le curseur materiel
        mov     ax, bp                           ; restaure AL = caractere
.dev_i2c_loop:
        call    i2c_lcd_data
        loop    .dev_i2c_loop
        jmp     .done

.dev_uart:
        ; AL est deja le caractere a transmettre (aucun acces a
        ; VAR_SEG necessaire - pas de curseur pour ce device)
.dev_uart_loop:
        call    uart_tx_byte
        loop    .dev_uart_loop

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

; ============================================================
; int10h_print_string
; Affiche une chaine terminee par 0 (jusqu'a 20 caracteres pour les
; LCD) via INT 10h (AH=09h) - procedure appelee par la macro "print"
; (include/lcd_macros.inc), la facon normale d'utiliser cette
; interface.
;
; LCD (BH=1) / LCD I2C (BH=2): relit la position de depart courante
; DU DEVICE CONCERNE (deja fixee par un "gotoxy ligne, colonne,
; device" prealable - voir int10h_handler, AH=02h), puis positionne
; (AH=02h) et ecrit (AH=09h) CARACTERE PAR CARACTERE, en avancant la
; colonne a chaque fois: AH=09h ne deplace PAS le curseur logique
; (meme convention que le vrai BIOS), il faut donc repositionner
; explicitement avant CHAQUE caractere.
;
; UART (BH=3): un flux serie n'a pas de position - transmet
; directement chaque caractere (AH=09h seul, un "gotoxy" prealable y
; serait un no-op de toute facon - voir int10h_handler).
;
; Entree:  BH = device (LCD/LCDI2C/UART - voir include/lcd_macros.inc),
;          DS:SI = texte termine par 0
; Detruit: rien (AX/BX/CX/DX/SI/DI/ES tous preserves)
; ============================================================
int10h_print_string:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        mov     bl, 0                    ; BL = couleur, N/A pour l'instant

        cmp     bh, 3
        je      .uart_loop

        ; --- LCD / LCD I2C: relit la position de depart courante DE
        ; CE DEVICE (deja fixee par gotoxy) ---
        mov     ax, VAR_SEG
        mov     es, ax
        cmp     bh, 2
        je      .read_lcdi2c
        mov     di, BIOS_CURSOR_LCD_ROW_OFF
        mov     dh, [es:di]
        mov     di, BIOS_CURSOR_LCD_COL_OFF
        mov     dl, [es:di]
        jmp     .next_char_lcd
.read_lcdi2c:
        mov     di, BIOS_CURSOR_LCDI2C_ROW_OFF
        mov     dh, [es:di]
        mov     di, BIOS_CURSOR_LCDI2C_COL_OFF
        mov     dl, [es:di]

.next_char_lcd:
        mov     al, [si]
        cmp     al, 0
        je      .done
        mov     ah, 02h
        int     10h                      ; positionne (DH,DL) sur BH - AX/BX
                                          ; preserves par int10h_handler
        mov     ah, 09h
        mov     cx, 1                    ; un seul caractere
        int     10h                      ; ecrit AL a (DH,DL) sur BH
        inc     si
        inc     dl
        jmp     .next_char_lcd

.uart_loop:
        mov     al, [si]
        cmp     al, 0
        je      .done
        mov     ah, 09h
        mov     cx, 1
        int     10h                      ; BH=3 -> transmission directe, sans position
        inc     si
        jmp     .uart_loop

.done:
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

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
txt_banniere2:          db      'Plan: seg 0000h (00000h-0FFFFh, 64 blocs) + seg 1000h (10000h-1F7FFh, 62 blocs)',13,10,'2 Ko reserves a la pile + tampon Edit RAM + copie fantome PA7: 1F800h-1FFFFh (non testes)',13,10,13,10,0

txt_ram_ok:             db      27,'[32m','*** RAM OK - 129024 octets testes (126 blocs de 1 Ko), aucune erreur ***',27,'[0m',13,10,13,10,0
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

; ---- registres CPU (voir registers_dump_action) - affichage UART,
; ---- format "DEBUG.COM" etendu (hexa + BINAIRE - voir
; ---- print_reg_hex_bin_uart), 2 registres par ligne: "AX=.. BX=.."
; ---- / "CX=.. DX=.." / "SI=.. DI=.." / "SP=.. BP=.." / "DS=.. ES=.."
; ---- / "SS=.. CS=.." / "IP=..", puis FLAGS SEUL sur sa ligne
; ---- ("FLAGS=xxxx  " suivi des 8 mnemoniques, txt_flag_*_set/clear
; ---- plus bas) ----
txt_reg_banniere:       db      27,'[34m','=== Registres CPU (8088) ===',27,'[0m',13,10,0
txt_reg_ax:             db      'AX=', 0
txt_reg_bx:             db      'BX=', 0
txt_reg_cx:             db      'CX=', 0
txt_reg_dx:             db      'DX=', 0
txt_reg_sp:             db      'SP=', 0
txt_reg_bp:             db      'BP=', 0
txt_reg_si:             db      'SI=', 0
txt_reg_di:             db      'DI=', 0
txt_reg_ds:             db      'DS=', 0
txt_reg_es:             db      'ES=', 0
txt_reg_ss:             db      'SS=', 0
txt_reg_cs:             db      'CS=', 0
txt_reg_ip:             db      'IP=', 0
txt_reg_pair_sep:       db      '    ', 0       ; separateur entre 2 registres
                                                 ; sur la meme ligne UART
txt_reg_flags_prefix:   db      'FLAGS=', 0
txt_reg_flags_sep:      db      '  ', 0

; ---- mnemoniques FLAGS (convention DEBUG.COM: OV/NV=overflow,
; ---- DN/UP=direction, EI/DI=interruptions, NG/PL=signe, ZR/NZ=zero,
; ---- AC/NA=retenue auxiliaire, PE/PO=parite, CY/NC=retenue) -
; ---- l'etat "actif" (bit=1) est en jaune (voir uart_flag_bit,
; ---- section macros) pour ressortir a l'oeil sur le terminal ----
txt_flag_of_set:        db      27,'[33m','OV',27,'[0m',' ',0
txt_flag_of_clear:      db      'NV', ' ', 0
txt_flag_df_set:        db      27,'[33m','DN',27,'[0m',' ',0
txt_flag_df_clear:      db      'UP', ' ', 0
txt_flag_if_set:        db      27,'[33m','EI',27,'[0m',' ',0
txt_flag_if_clear:      db      'DI', ' ', 0
txt_flag_sf_set:        db      27,'[33m','NG',27,'[0m',' ',0
txt_flag_sf_clear:      db      'PL', ' ', 0
txt_flag_zf_set:        db      27,'[33m','ZR',27,'[0m',' ',0
txt_flag_zf_clear:      db      'NZ', ' ', 0
txt_flag_af_set:        db      27,'[33m','AC',27,'[0m',' ',0
txt_flag_af_clear:      db      'NA', ' ', 0
txt_flag_pf_set:        db      27,'[33m','PE',27,'[0m',' ',0
txt_flag_pf_clear:      db      'PO', ' ', 0
txt_flag_cf_set:        db      27,'[33m','CY',27,'[0m',' ',0
txt_flag_cf_clear:      db      'NC', ' ', 0

; ---- gestionnaire par defaut de l'IVT (voir init_ivt_not_implemented/
; ---- int_not_implemented) ----
txt_int_non_implementee: db     27,'[31m','*** Interruption non implementee ***',27,'[0m',13,10,0

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
                        db      '3) Registres CPU',13,10
                        db      '4) Edit+Run RAM',13,10
                        db      '(Echap: retour au menu principal)',13,10,13,10,0

; ---- invite "Edit RAM" (voir edit_ram_action) ----
txt_edit_address_prefix: db     'Address: 0x', 0
txt_edit_size_prefix:   db      'Size:    0x', 0
txt_edit_help:           db     27,'[36m','Fleches G/D: colonne | Fleches H/B: ligne (defilement) | chiffre hexa: editer | Entree: valider la case | Q: enregistrer tout | Echap: annuler tout',27,'[0m',13,10,13,10,0

txt_edit_ivt_reject:    db      27,'[31m',"*** Adresse dans l'IVT (< 0x0400) - edition annulee ***",27,'[0m',13,10,13,10,0
txt_edit_size_invalid:  db      27,'[31m','*** Taille invalide (1-1024 octets, dans les limites du segment) - edition annulee ***',27,'[0m',13,10,13,10,0

; ---- invites "Edit+Run RAM" (voir edit_run_action) ----
txt_run_address:        db      27,'[36m',"Adresse fixe: 1000:0000 (2e bloc de 64K, 255 octets)",27,'[0m',13,10,0
txt_run_help:            db     27,'[36m','Fleches G/D: colonne | Fleches H/B: ligne (defilement) | chiffre hexa: editer (2e chiffre valide automatiquement, Entree optionnelle pour 1 seul chiffre) | Q: enregistrer (sans executer) | R: enregistrer et executer (RETF attendu a la fin, reconnue meme pendant la saisie) | Echap: annuler tout',27,'[0m',13,10,13,10,0
txt_run_result_banner:  db      27,'[34m','=== Execution terminee (1000:0000, RETF) - Registres ===',27,'[0m',13,10,0

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

; ---- menu Dump memory (voir start:) - les 4 lignes sont utilisees
; ---- depuis l'ajout de l'option "3) Registres CPU"; "9) Home menu"
; ---- a ete remplacee par "4) Edit+Run RAM" - Echap (non affiche a
; ---- l'ecran) fait maintenant office de retour au menu principal ----
lcd_text lcd_txt_menu_dump_l1, '1) Dump memory', 20
lcd_text lcd_txt_menu_dump_l2, '2) Edit RAM', 20
lcd_text lcd_txt_menu_dump_l3, '3) Registres CPU', 20
lcd_text lcd_txt_menu_dump_l4, '4) Edit+Run RAM', 20

; ---- registres CPU (voir registers_dump_action) - prefixes courts
; ---- (LCD 4x20, contrairement aux prefixes UART txt_reg_* qui
; ---- incluent leur propre separation) et indicateur de page ----
txt_lcd_reg_ax:         db      'AX=', 0
txt_lcd_reg_bx:         db      'BX=', 0
txt_lcd_reg_cx:         db      'CX=', 0
txt_lcd_reg_dx:         db      'DX=', 0
txt_lcd_reg_si:         db      'SI=', 0
txt_lcd_reg_di:         db      'DI=', 0
txt_lcd_reg_sp:         db      'SP=', 0
txt_lcd_reg_bp:         db      'BP=', 0
txt_lcd_reg_cs:         db      'CS=', 0
txt_lcd_reg_ds:         db      'DS=', 0
txt_lcd_reg_es:         db      'ES=', 0
txt_lcd_reg_ss:         db      'SS=', 0
txt_lcd_reg_ip:         db      'IP=', 0
txt_lcd_reg_fl:         db      'FL=', 0
txt_lcd_page1:          db      '1/2', 0
txt_lcd_page2:          db      '2/2', 0

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

; ---- ligne 4 de l'etape 2: "Bloc:" + dec3 + "/126 Def:" + dec3 =
; ---- 5+3+9+3 = 20 caracteres EXACTEMENT (pas de padding requis) ----
lcd_txt_bloc_prefix:    db      'Bloc:', 0
lcd_txt_bloc_mid:       db      '/126 Def:', 0

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
