; ============================================================
; lcd_macros.inc
; Macros lcd_goto/lcd_show (LCD parallele) et i2c_lcd_goto/i2c_lcd_show
; (LCD I2C) - positionnement DDRAM (+ affichage) sur les 4 lignes
; d'un afficheur 4x20, en remplacement des anciennes procedures
; lcd_line1..4/lcd_show_line1..4 (lib/lcd.asm) et i2c_lcd_line1..4/
; i2c_lcd_show_line1..4 (lib/lcd_i2c.asm), qui etaient 8 procedures
; quasi identiques (seule l'adresse DDRAM changeait). Desormais
; generees INLINE a chaque appel plutot que via un "call" vers une
; procedure partagee - legere augmentation du code assemble (~5-6
; octets par appel, au lieu d'un "call" de 3 octets vers une
; procedure partagee), en echange d'une source bien plus compacte.
;
; Usage (remplace "call lcd_lineN" / "call lcd_show_lineN"):
;   lcd_goto LCD_LINE1
;   lcd_show LCD_LINE2      ; DS:SI doit deja pointer sur le texte
;
; Comme include/delay.inc, ce fichier n'emet AUCUN octet (macros et
; equ seulement) - il peut donc etre inclus n'importe ou avant le
; premier usage, meme avant start:, sans deplacer les VRAIES
; procedures (lcd_command/lcd_print/i2c_lcd_command/i2c_lcd_print),
; qui doivent rester dans lib/lcd.asm et lib/lcd_i2c.asm, %include
; APRES start: (voir la note pres de ces %include dans
; solution-01.asm) - seul un CALL peut etre resolu "en avant" par
; NASM, jamais une invocation de macro (qui doit etre textuellement
; definie avant son premier usage dans le flux assemble).
; ============================================================
%ifndef LCD_MACROS_INC
%define LCD_MACROS_INC

; --- adresses DDRAM pour un afficheur 4x20: la ligne 3 est en fait
; --- la suite de la ligne 1 en memoire interne (00h puis 14h), et
; --- la ligne 4 la suite de la ligne 2 (40h puis 54h) - convention
; --- standard ("type A") des afficheurs 20x4 bases sur le HD44780.
; --- Memes adresses pour le LCD parallele ET le LCD I2C (meme
; --- controleur HD44780, peu importe le transport). ---
LCD_LINE1       equ     10000000b       ; Set DDRAM Address = 80h | 00h
LCD_LINE2       equ     11000000b       ; Set DDRAM Address = 80h | 40h
LCD_LINE3       equ     10010100b       ; Set DDRAM Address = 80h | 14h
LCD_LINE4       equ     11010100b       ; Set DDRAM Address = 80h | 54h

; %1 = LCD_LINE1..4 - positionne le curseur DDRAM (LCD parallele).
%macro lcd_goto 1
        push    ax
        mov     al, %1
        call    lcd_command
        pop     ax
%endmacro

; %1 = LCD_LINE1..4 - positionne PUIS affiche DS:SI (LCD parallele).
%macro lcd_show 1
        lcd_goto %1
        call    lcd_print
%endmacro

; %1 = LCD_LINE1..4 - positionne le curseur DDRAM (LCD I2C).
%macro i2c_lcd_goto 1
        push    ax
        mov     al, %1
        call    i2c_lcd_command
        pop     ax
%endmacro

; %1 = LCD_LINE1..4 - positionne PUIS affiche DS:SI (LCD I2C).
%macro i2c_lcd_show 1
        i2c_lcd_goto %1
        call    i2c_lcd_print
%endmacro

%endif ; LCD_MACROS_INC
