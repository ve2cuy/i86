; ============================================================
; hardware.inc
; Constantes materielles partagees (8255 PIO + adressage RAM des
; variables partagees). Inclus par solution-01.asm ET par chaque
; module de ./lib qui en a besoin (assemblage standalone via le
; Makefile) - d'ou la garde ci-dessous.
;
; IMPORTANT: tous les %include de ce projet sont ecrits comme des
; chemins relatifs a la RACINE du dossier Solution-01 (ex:
; "include/hardware.inc", "lib/common.asm") - PAS relatifs au
; fichier qui fait le %include. NASM resout les %include par
; rapport au repertoire courant (cwd) au moment de l'assemblage,
; jamais par rapport a l'emplacement du fichier. Le Makefile lance
; donc TOUJOURS nasm depuis la racine de Solution-01, meme pour
; assembler un module de ./lib tout seul.
; ============================================================
%ifndef HARDWARE_INC
%define HARDWARE_INC

;*****************
; CONST. PIO 1   *
;*****************
PORTA       EQU    10000000B   ;8255 ACTIVE PAR A7
PORTB       EQU    10000001B
PORTC       EQU    10000010B
PIO         EQU    10000011B

; MASQUE_PIO: mot de mode du 8255 (mode 0). Port B en ENTREE (bit1=1)
; en PERMANENCE depuis que le menu interactif (solution-01.asm) a
; besoin du clavier PS/2 (lib/ps2.asm, PB0=CLOCK, PB1=DATA) des la
; sortie du splash - ce n'etait conditionnel a TEST_PS2 qu'au premier
; jalon (voir Directives.md), quand le clavier n'etait qu'un test
; optionnel. Le Port A (LCD/UART/LCD-I2C) et le Port C (chenillard)
; restent TOUJOURS en sortie.
MASQUE_PIO  EQU    10000010B   ;PORT A ET C EN SORTIE, PORT B EN ENTREE (PS/2)

;*****************
; CONST. 8259   *
;*****************
; CS# du 8259 decode via IO.A6./A7 (NAND 3 entrees) - memes ports que
; le PC/XT reel (20h/21h). A0 du 8259 (commande/ICW1/OCW2/OCW3 vs
; donnees/ICW2/ICW4/OCW1=IMR) correspond a l'ecart d'un octet entre
; PIC_CMD et PIC_DATA, comme PORTA/PORTB/PORTC/PIO ci-dessus pour le
; 8255 (voir Directives.md pour la discussion du decodage).
PIC_CMD     EQU    00100000B   ;8259 - registre de commande (ICW1/OCW2/OCW3)
PIC_DATA    EQU    00100001B   ;8259 - registre de donnees (ICW2/ICW4/OCW1=IMR)

; --- copie fantome du port A + compteurs de progression du test RAM
; --- + etat de l'editeur RAM + tampon d'edition (edit_ram_action,
; --- solution-01.asm) + etat de dump_memory_action + curseurs
; --- "esprit BIOS": vivent dans une zone de 2 Ko reservee a la fin du
; --- segment VAR_SEG (agrandie de 1 a 2 Ko pour loger le tampon
; --- d'edition de 1024 octets - voir test_ram, solution-01.asm, pour
; --- le nombre d'octets reellement testes en consequence). ---
VAR_SEG             equ     1000h

; --- tampon de travail de edit_ram_action (1024 octets max) - toute
; --- l'edition se fait ICI, jamais directement en RAM reelle: Echap
; --- abandonne ce tampon (rien n'est ecrit), Q/q le recopie dans la
; --- RAM reelle (voir edit_ram_load_buffer/edit_ram_commit_buffer).
; --- Occupe a lui seul la moitie de la zone reservee. ---
EDIT_BUFFER_OFF     equ     0F800h  ; 1024 octets: 0F800h-0FBFFh

PORTA_SHADOW_OFF    equ     0FC00h
BLOCK_COUNTER_OFF   equ     0FC01h  ; numero du bloc courant (1-127)
DEFECT_COUNTER_OFF  equ     0FC02h  ; nombre de blocs ayant eu >=1 defaut

; --- etat de edit_ram_action: adresse/taille de la plage saisie, et
; --- position courante dans le tampon (curseur logique + fenetre
; --- visible, pour le defilement quand la plage depasse les 4
; --- lignes du LCD) ---
EDIT_BASE_OFF       equ     0FC03h  ; adresse de depart de la plage (mot)
EDIT_SIZE_OFF       equ     0FC05h  ; taille de la plage en octets, 1-400h (mot)
EDIT_CURSOR_OFF     equ     0FC07h  ; position lineaire du curseur dans le
                                     ; tampon, 0 a (taille-1) (mot)
EDIT_WINDOW_ROW_OFF equ     0FC09h  ; ligne LOGIQUE (0-based, pas de deplacement
                                     ; en colonnes) affichee en haut de l'ecran (mot)

; --- adresses saisies par dump_memory_action (solution-01.asm), le
; --- temps de calculer les adresses physiques de depart/fin - voir
; --- son en-tete ---
DUMP_START_SEG_OFF   equ    0FC0Bh  ; segment de depart saisi (mot)
DUMP_START_OFF_OFF   equ    0FC0Dh  ; offset de depart saisi (mot)
DUMP_END_SEG_OFF     equ    0FC0Fh  ; segment de fin saisi (mot)
DUMP_END_OFF_OFF     equ    0FC11h  ; offset de fin saisi (mot)
; --- adresse physique de fin (32 bits), memorisee une fois calculee -
; --- comparee a l'adresse physique COURANTE a chaque ligne plutot que
; --- de precalculer un nombre total de lignes (qui pourrait deborder
; --- 16 bits: exactement 65536 lignes pour la plage maximale de ce
; --- materiel, 0000:0000 a F000:FFFF - voir dump_memory_action) ---
DUMP_END_PHYS_LO_OFF equ    0FC13h  ; poids faible (mot)
DUMP_END_PHYS_HI_OFF equ    0FC15h  ; poids fort (mot)

; --- curseurs logiques de int10h_handler (solution-01.asm), AH=02h/
; --- 09h "esprit BIOS" - UN JEU PAR DEVICE (LCD parallele / LCD I2C)
; --- depuis l'ajout des macros gotoxy/print (voir
; --- include/lcd_macros.inc et l'en-tete de int10h_handler). UART
; --- n'a pas de curseur (flux serie, AH=02h y est un no-op). ---
BIOS_CURSOR_LCD_ROW_OFF    equ 0FC17h  ; LCD parallele: ligne courante (0-3)
BIOS_CURSOR_LCD_COL_OFF    equ 0FC18h  ; LCD parallele: colonne courante (0-19)
BIOS_CURSOR_LCDI2C_ROW_OFF equ 0FC19h  ; LCD I2C: ligne courante (0-3)
BIOS_CURSOR_LCDI2C_COL_OFF equ 0FC1Ah  ; LCD I2C: colonne courante (0-19)

; --- registres GENERAUX persistants d'edit_run_action (solution-01.asm):
; --- restaures juste AVANT chaque "call 1000h:0000h" et resauvegardes
; --- juste APRES son retour (RETF) - sans cette persistance, AX/BX/CX/
; --- DX/SI/DI seraient ecrases entre deux appuis sur 'r' par le code de
; --- menu/clavier qui s'execute entre-temps (edit_ram_draw_grid,
; --- ps2_get_char, etc.), rendant impossible tout test CUMULATIF (ex:
; --- "add ax,2" repete, cense incrementer AX a chaque execution).
; --- Remis a 0 UNE SEULE FOIS, a l'entree dans edit_run_action (nouvelle
; --- session d'edition) - voir edit_run_action/edit_run_execute_and_show. ---
RUN_REG_AX_OFF      equ 0FC1Bh  ; (mot)
RUN_REG_BX_OFF      equ 0FC1Dh  ; (mot)
RUN_REG_CX_OFF      equ 0FC1Fh  ; (mot)
RUN_REG_DX_OFF      equ 0FC21h  ; (mot)
RUN_REG_SI_OFF      equ 0FC23h  ; (mot)
RUN_REG_DI_OFF      equ 0FC25h  ; (mot)

%endif ; HARDWARE_INC
