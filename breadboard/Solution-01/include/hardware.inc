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

; --- copie fantome du port A + compteurs de progression du test RAM
; --- + etat de l'editeur RAM (edit_ram_action, solution-01.asm):
; --- vivent dans la zone deja reservee a la pile (segment VAR_SEG,
; --- tout debut du dernier Ko non teste - voir "1 Ko reserve a la
; --- pile" dans test_ram, solution-01.asm). 7 octets utilises sur
; --- 1024 reserves. ---
VAR_SEG             equ     1000h
PORTA_SHADOW_OFF    equ     0FC00h
BLOCK_COUNTER_OFF   equ     0FC01h  ; numero du bloc courant (1-127)
DEFECT_COUNTER_OFF  equ     0FC02h  ; nombre de blocs ayant eu >=1 defaut
EDIT_BASE_OFF       equ     0FC03h  ; adresse de base de la grille d'edition (mot)
EDIT_ROW_OFF        equ     0FC05h  ; ligne courante du curseur (0-3)
EDIT_COL_OFF        equ     0FC06h  ; colonne courante du curseur (0-5)

; --- adresses saisies par dump_memory_action (solution-01.asm), le
; --- temps de calculer les adresses physiques de depart/fin - voir
; --- son en-tete ---
DUMP_START_SEG_OFF  equ     0FC07h  ; segment de depart saisi (mot)
DUMP_START_OFF_OFF  equ     0FC09h  ; offset de depart saisi (mot)
DUMP_END_SEG_OFF    equ     0FC0Bh  ; segment de fin saisi (mot)
DUMP_END_OFF_OFF    equ     0FC0Dh  ; offset de fin saisi (mot)
DUMP_LINES_LEFT_OFF equ     0FC0Fh  ; lignes de 16 octets restant a
                                     ; afficher (mot, decompte - voir
                                     ; dump_memory_action: dump_line
                                     ; detruit CX, un compteur "loop"
                                     ; classique n'y survivrait pas)

; --- curseur logique de int10h_handler (solution-01.asm), AH=02h/09h
; --- "esprit BIOS" - partage entre les 2 afficheurs (LCD parallele/
; --- LCD I2C), voir l'en-tete de int10h_handler ---
BIOS_CURSOR_ROW_OFF equ     0FC11h  ; ligne courante (0-3)
BIOS_CURSOR_COL_OFF equ     0FC12h  ; colonne courante (0-19)

%endif ; HARDWARE_INC
