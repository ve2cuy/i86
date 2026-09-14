; ------------------------------------------------------------
; lcd_hello_6.asm
; nasm -f bin lcd_hello_6.asm -o Z:\Partage\Alain\lcd_hello_6.bin
; ------------------------------------------------------------
; Reprend le "Hello World" LCD (voir lcd_hello.asm / lcd_hello_5.asm)
; mais deplace TOUTE la logique du latch sur le port 10h vers le
; Port A du 8255 nouvellement ajoute au montage (decode A7+IO,
; voir ram_test_uart_3.asm ou le 8255 a ete valide: "ca fonctionne
; parfaitement").
;
; Ce qui NE CHANGE PAS: le mapping des bits (D4-D7/RS/E), la
; sequence d'initialisation HD44780 4 bits, les delais - tout ca
; a deja ete verifie correct au niveau protocole. Ce qui change:
; la seule et unique destination des "out" (10h -> PORTA), plus
; l'ajout de l'initialisation du 8255 lui-meme (obligatoire avant
; toute utilisation: par defaut, un 8255 sort de reset avec ses
; 3 ports en ENTREE - sans le "OUT PIO,MASQUE_PIO" ci-dessous,
; Port A ne piloterait rien du tout).
;
; Hypothese: le latch sur 10h ne posait peut-etre pas de probleme
; de sequence, mais un probleme electrique (partage avec l'UART/
; les LED, tenue du niveau logique, courant d'attaque...). Le
; 8255 est un choix beaucoup plus classique pour piloter un LCD
; en parallele - si le protocole etait deja bon, ca devrait
; passer cette fois.
;
; Cablage: Port A du 8255 (PA0-PA7) -> LCD:
;   PA0-PA3 -> D4-D7 du LCD (D4=PA0, D5=PA1, D6=PA2, D7=PA3)
;   PA4     -> RS (0=commande, 1=donnee)
;   PA5     -> non utilise (R/W du LCD relie DIRECTEMENT a la masse,
;              comme avant - pas de lecture du "busy flag" possible)
;   PA6     -> E (impulsion de capture, front descendant)
;   PA7     -> libre
; ------------------------------------------------------------

BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

STACK_SEG       equ     1000h

; ------------------------------------------------------------
; 8255 (PIO) - memes constantes/valeurs que ram_test_uart_3.asm,
; ou le 8255 a ete valide sur le materiel. Decode: CS8255_ =
; NAND(A7,IO) -> mirroir dans 80h-FFh, base choisie ici = 80h.
; ------------------------------------------------------------
PORTA       equ     10000000b   ; 80h - donnees LCD (D4-D7,RS,E)
PIO         equ     10000011b   ; 83h - registre de mot de controle
MASQUE_PIO  equ     10000000b   ; port A, B et C en SORTIE (mode 0)

; ------------------------------------------------------------
; Mapping des bits de PORTA (identique a l'ancien latch 10h)
; ------------------------------------------------------------
LCD_RS          equ     00010000b       ; bit4
; LCD_RW          equ     00100000b       ; bit5 (jamais mis a 1 ici)
LCD_E           equ     01000000b       ; bit6
LCD_E_MASK_OFF  equ     10111111b       ; pour effacer le bit E (AND)

start:
        cli
        mov     ax, STACK_SEG
        mov     ss, ax          ; SS = 1000h -> pile en fin de RAM (128K)
        mov     sp, 0000h
        sti

        mov     ax, cs
        mov     ds, ax          ; DS = CS: ce programme ne touche pas la RAM
                                 ; testee ailleurs, seulement les chaines de
                                 ; caracteres stockees ici, dans la ROM.

        call    init_8255       ; INDISPENSABLE avant tout OUT PORTA: sans
                                 ; ca, le 8255 sort de reset en mode ENTREE
        call    lcd_init

        mov     si, msg_line1
        call    lcd_print

        mov     al, 11000000b   ; "Set DDRAM Address" = 80h | 40h (debut ligne 2,
        call    lcd_command     ; adresse 40h - convention standard HD44780 2 lignes)

        mov     si, msg_line2
        call    lcd_print

.halt:
        jmp     .halt           ; Hello World de validation: on s'arrete ici
                                 ; (PAS de reinit en boucle - voir lcd_hello_5.asm:
                                 ; reinitialiser sans arret ne fait que fragiliser
                                 ; le diagnostic, on veut un texte FIXE a l'ecran)

; ============================================================
; init_8255
; Configure le 8255: mot de controle = ports A/B/C en sortie
; (mode 0), puis met PORTA a 0 (ligne E au repos, RS=commande).
; ============================================================
init_8255:
        push    ax
        mov     al, MASQUE_PIO
        out     PIO, al         ; mot de controle: A,B,C en sortie
        mov     al, 0
        out     PORTA, al       ; etat de repos: E=0, RS=0, donnees=0
        pop     ax
        ret

; ============================================================
; lcd_init
; Sequence d'initialisation standard HD44780 en mode 4 bits.
; Les 3 premiers envois sont des QUARTETS ISOLES (le LCD demarre
; en supposant du 8 bits, donc il ignore le "second quartet"
; tant qu'on ne lui a pas dit de passer en 4 bits) - voir
; datasheet HD44780, sequence de reveil en mode 4 bits.
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
; Entree: AL = octet a envoyer. CX est utilise en interne.
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
; Envoie UN quartet deja pret (bits0-3 = donnee, bit4 = RS deja
; positionne par l'appelant, bit5 = R/W toujours 0). Genere
; l'impulsion E (front descendant = capture reelle par le LCD).
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
; Affiche une chaine terminee par 00h. Entree: DS:SI = adresse
; de la chaine.
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
; Delais - PAS de lecture du drapeau "busy" possible dans ce
; montage (R/W force a la masse), donc tout est base sur des
; delais fixes, larges par prudence - memes valeurs que la
; version latch, deja eprouvees.
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

; ---- messages -------------------------------------------------
msg_line1:      db      'Hello, World!', 0
msg_line2:      db      'Ligne 2 : OK', 0

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
