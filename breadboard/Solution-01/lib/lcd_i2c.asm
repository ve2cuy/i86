; ============================================================
; lcd_i2c.asm
; Deuxieme afficheur LCD (HD44780 derriere un expandeur I2C
; PCF8574, adresse 0x27 - "backpack" standard le plus courant, ex.
; "LCM1602 IIC"), pilote en I2C logiciel (bit-bang) sur 2 bits du
; Port A du 8255:
;   PA5 = SDA
;   PA0 = SCL - PARTAGEE avec D4 du LCD PARALLELE (lcd.asm). PA5
;         etait le SEUL bit encore libre sur tout le Port A
;         (PA0-PA3=D4-D7, PA4=RS, PA6=E, PA7=UART - voir l'en-tete
;         de solution-01.asm), donc pas assez pour SDA+SCL seuls:
;         SCL reutilise PA0. Contrairement a un partage avec E
;         (PA6, essaye puis abandonne), ce choix est SANS RISQUE
;         de corruption meme si le LCD parallele affiche du contenu
;         actif pendant une transaction I2C: le HD44780 ne capture
;         quoi que ce soit sur D4-D7/RS que sur un front descendant
;         de E (voir lcd_strobe dans lcd.asm) - or ce module ne
;         touche JAMAIS a PA6/E. Le bruit I2C sur PA0/D4 est donc
;         invisible au LCD parallele tant que E ne bouge pas.
;         Consequence: i2c_lcd_* peut etre appele N'IMPORTE OU dans
;         le projet, y compris en plein milieu d'un affichage actif
;         sur le LCD parallele, sans avoir besoin d'un lcd_init
;         apres coup.
;
; Contrainte materielle importante: le 8255 (mode 0) configure TOUT
; le Port A en SORTIE - ses broches sont donc des sorties push-pull
; classiques, PAS open-drain comme l'exige le standard I2C.
; Consequence: cette implementation N'ACCUSE JAMAIS reception (ACK)
; - elle maintient systematiquement SDA a 0 pendant le 9e coup
; d'horloge de chaque octet (au lieu de le relacher a 1 comme le
; ferait un vrai maitre I2C), ce qui evite toute contention
; electrique avec le PCF8574 (qui, lui, tenterait reellement de
; tirer SDA a 0 pour acquitter) mais ne verifie jamais que
; l'expandeur a bien repondu. Ecriture seule, sans lecture ni
; pull-up externe necessaire - suffisant pour piloter un LCD en
; affichage seulement.
;
; Repositionnement PCF8574 -> HD44780 (backpack standard):
;   P0=RS  P1=RW(toujours 0, ecriture seule)  P2=EN  P3=Retroeclairage
;   P4-P7 = D4-D7
;
; Vitesse SCL: voir i2c_delay (~45-66 kHz, sous le maximum 100 kHz
; du mode I2C "standard" - large marge pour absorber la tolerance
; des composants/cablage reels sur breadboard).
;
; Delais d'execution du HD44780 lui-meme (37-43us / >=1,52ms /
; >=4,1ms / >=15ms): REUTILISES depuis lib/lcd.asm (lcd_delay/
; lcd_delay_long/lcd_powerup_delay) - ce sont les memes exigences
; du meme controleur HD44780, peu importe qu'il soit pilote en
; parallele ou via I2C (le protocole I2C lui-meme, plus lent qu'un
; acces parallele direct, couvre deja largement les delais courts
; - voir i2c_lcd_strobe - mais PAS le temps d'execution long du
; Clear Display, d'ou la reutilisation explicite de lcd_delay_long).
;
; Garde requise (voir hardware.inc) puisque solution-01.asm inclut
; ce fichier directement. Chemins d'%include toujours relatifs a
; la racine de Solution-01 (voir hardware.inc).
; ============================================================
%ifndef LCD_I2C_ASM
%define LCD_I2C_ASM

%include "include/hardware.inc"
%include "lib/common.asm"
%include "lib/lcd.asm"          ; reutilise lcd_delay/lcd_delay_long/lcd_powerup_delay

I2C_SDA         equ     00100000b       ; PA5
I2C_SCL         equ     00000001b       ; PA0 (partagee avec D4 du LCD parallele -
                                         ; sans risque, voir l'en-tete: seul E/PA6
                                         ; declenche une capture sur le LCD parallele)
I2C_MASK        equ     00100001b       ; bits 0 et 5 (SDA+SCL)
I2C_BASE_MASK   equ     11011110b       ; NOT(I2C_MASK): efface SDA+SCL, garde le
                                         ; reste du Port A (D5-D7,RS,E,UART/PA7)

I2C_LCD_ADDR    equ     027h            ; adresse I2C 7 bits du PCF8574 (backpack LCD)

I2C_LCD_RS      equ     00000001b       ; P0 du PCF8574
I2C_LCD_RW      equ     00000010b       ; P1 (jamais utilise: ecriture seule)
I2C_LCD_EN      equ     00000100b       ; P2
I2C_LCD_BL      equ     00001000b       ; P3 - retroeclairage, toujours actif ici

; ============================================================
; i2c_delay
; Demi-periode SCL. Meme motif d'instruction (dec bx/jnz) que les
; autres delais du projet (voir lib/utils.asm, INNER_MS=265 pour
; ~1ms a 4,77MHz) -> 1 iteration ~3,77us. bx=1 -> ~3,77us/appel - 3
; appels par bit (voir i2c_write_byte) -> cycle SCL complet ~11,3us
; -> ~88,5kHz, sous le maximum 100kHz du mode I2C "standard" mais
; avec une marge nettement plus serree (~13%) que la valeur
; precedente (bx=2, ~44,4kHz, ~125% de marge). A resserrer en
; PREMIER (revenir a bx=2) si le LCD I2C devient instable sur le
; materiel reel - voir Directives.md pour la mesure qui a motive
; cette reduction (peu d'effet percu par rapport a l'optimisation
; precedente, qui eliminait l'essentiel de la surcharge d'appels -
; celle-ci ne reduit que le plancher impose par i2c_delay lui-meme,
; ~189 appels par transaction). Generee par def_busy_delay
; (lib/common.asm) - meme motif que lcd_short_delai/lcd_delay/
; lcd_delay_long (lib/lcd.asm) et uart_bit_delay (lib/uart.asm).
; ============================================================
def_busy_delay i2c_delay, 0001h

; ============================================================
; i2c_start / i2c_stop / i2c_write_byte - ECRITURE PORT A "RAPIDE"
;
; Version 1: chaque bit passait par i2c_set (relit la copie fantome
; via porta_write - lecture-modification-ecriture complete, 5
; push/pop - a CHAQUE bit). Un dump de 16 octets (48 caracteres/
; commandes envoyes au LCD I2C) prenait plus de 2,5 secondes sur le
; materiel reel (voir Directives.md).
;
; Version 2: la copie fantome n'etait plus relue qu'UNE FOIS par
; appel (pas par bit), via ES:DI - deja un gain important.
;
; Version 3 (actuelle): la copie fantome RAM (PORTA_SHADOW) n'est
; plus utilisee DU TOUT par ces 3 routines - remplacee par une
; lecture materielle directe "IN AL, PORTA". Fiable sur un 8255A
; authentique (confirme sur ce montage): un port configure en
; SORTIE renvoie, a la lecture, le contenu du VERROU DE SORTIE (pas
; l'etat electrique des broches) - comportement documente de la
; puce Intel 8255A (peut varier sur certains clones non garantis
; equivalents - a valider si le 8255 change un jour sur ce montage).
;
; Consequence: plus besoin de VAR_SEG/ES/DI ni de maintenir
; PORTA_SHADOW a jour depuis ce module - "IN AL,PORTA" (1
; instruction) remplace "mov ax,VAR_SEG / mov es,ax / mov
; di,PORTA_SHADOW_OFF / mov bl,[es:di]" (4 instructions, 2 registres
; supplementaires a sauvegarder). Sans danger pour porta_write
; (utilise par lcd.asm/uart.asm): aucun de ses appelants ne couvre
; les bits PA0(SCL)/PA5(SDA) dans son masque sauf le LCD parallele,
; qui ecrit TOUJOURS explicitement son propre bit D4/PA0 - la valeur
; laissee par l'I2C sur PA0/PA5 entre deux transactions n'a donc
; aucune influence sur le reste du projet.
;
; Toujours sans danger d'utiliser AL/BL/BH comme base+bits sans
; relire a chaque bit: aucune interruption ne pilote le Port A dans
; ce projet, et rien d'autre ne s'execute entre les etapes d'une
; meme transaction I2C.
; ============================================================
i2c_start:
        push    ax
        push    bx
        in      al, PORTA
        and     al, I2C_BASE_MASK      ; efface SDA/SCL, garde le reste
        mov     bl, al                 ; BL = base, pour toute la duree de i2c_start

        mov     al, bl
        or      al, I2C_MASK           ; SDA=1, SCL=1 (bus au repos)
        out     PORTA, al
        call    i2c_delay

        mov     al, bl
        or      al, I2C_SCL            ; SDA=0, SCL=1 -> condition START
        out     PORTA, al
        call    i2c_delay

        mov     al, bl                 ; SDA=0, SCL=0 (pret pour le 1er bit)
        out     PORTA, al
        call    i2c_delay

        pop     bx
        pop     ax
        ret

i2c_stop:
        push    ax
        push    bx
        in      al, PORTA
        and     al, I2C_BASE_MASK
        mov     bl, al

        mov     al, bl                 ; SDA=0, SCL=0
        out     PORTA, al
        call    i2c_delay

        or      al, I2C_SCL            ; SCL=1 (SDA toujours 0)
        out     PORTA, al
        call    i2c_delay

        or      al, I2C_MASK           ; SDA=1 pendant SCL=1 -> condition STOP
        out     PORTA, al
        call    i2c_delay

        pop     bx
        pop     ax
        ret

; ============================================================
; i2c_write_byte
; Transmet AL (8 bits, MSB en premier). Le 9e coup d'horloge (bit
; ACK) maintient SDA a 0 sans jamais le relacher a 1 - voir la note
; en en-tete du fichier (sorties push-pull, pas open-drain): l'ACK
; n'est donc jamais reellement verifie. Detruit AX/BX/CX/DX en
; apparence, mais les preserve tous via push/pop (comme porta_write/
; uart_tx_byte).
; ============================================================
i2c_write_byte:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     dl, al          ; DL = octet a transmettre (copie de travail)

        in      al, PORTA
        and     al, I2C_BASE_MASK
        mov     bl, al          ; BL = base, pour tout cet octet (9 bits) - voir
                                 ; i2c_start pour la justification de IN PORTA

        mov     cl, 8
.bitloop:
        mov     al, dl
        and     al, 10000000b
        jz      .bit0
        mov     bh, I2C_SDA     ; BH = bit SDA physique courant, SCL=0
        jmp     .have_bit
.bit0:
        mov     bh, 0
.have_bit:
        mov     al, bl
        or      al, bh          ; base + SDA, SCL=0 (donnee posee, horloge basse)
        out     PORTA, al
        call    i2c_delay

        or      al, I2C_SCL     ; SCL=1 (front montant: le PCF8574 lit SDA ICI)
        out     PORTA, al
        call    i2c_delay

        mov     al, bl
        or      al, bh          ; SCL=0 (fin du bit, SDA peut changer ensuite)
        out     PORTA, al
        call    i2c_delay

        shl     dl, 1
        dec     cl
        jnz     .bitloop

        ; --- 9e coup d'horloge (bit ACK, jamais verifie - voir en-tete) ---
        mov     al, bl          ; SDA=0, SCL=0
        out     PORTA, al
        call    i2c_delay
        or      al, I2C_SCL     ; SCL=1
        out     PORTA, al
        call    i2c_delay
        mov     al, bl          ; SCL=0
        out     PORTA, al
        call    i2c_delay

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; i2c_lcd_strobe
; Envoie un quartet (deja aligne sur D4-D7, bits4-7) + RS au LCD
; I2C, avec l'impulsion EN (EN=0, EN=1, EN=0) - les 3 ecritures
; PCF8574 sont REGROUPEES en UNE SEULE transaction I2C (1 START +
; 1 adresse + 3 octets de donnees + 1 STOP) plutot que 3 transactions
; separees comme dans la version initiale: l'overhead START/adresse/
; STOP n'est paye qu'une fois (~3x plus rapide sur ce quartet, voir
; Directives.md pour la mesure qui a motive ce changement). Meme
; sequence electrique cote HD44780, donc toujours bien plus longue
; que le minimum d'impulsion E exige.
; Entree: AL = quartet (bits4-7) + RS (bit0 = I2C_LCD_RS si donnee,
;         0 si commande). Le retroeclairage est ajoute automatiquement.
; ============================================================
i2c_lcd_strobe:
        push    ax
        push    bx
        or      al, I2C_LCD_BL  ; retroeclairage toujours actif
        mov     bh, al          ; BH = octet PCF8574 de base (EN=0)

        call    i2c_start
        mov     al, I2C_LCD_ADDR
        shl     al, 1           ; adresse 7 bits -> bit0 = R/W (0 = ecriture)
        call    i2c_write_byte

        mov     al, bh          ; EN=0 (donnee/RS deja en place)
        call    i2c_write_byte
        mov     al, bh
        or      al, I2C_LCD_EN  ; EN=1
        call    i2c_write_byte
        mov     al, bh          ; EN=0 (front descendant: capture reelle)
        call    i2c_write_byte

        call    i2c_stop

        pop     bx
        pop     ax
        ret

; ============================================================
; i2c_lcd_send_byte
; Envoie un octet complet (commande ou donnee) au LCD I2C: 2
; quartets x 3 etats EN, comme 2 appels a i2c_lcd_strobe - mais
; REGROUPES en UNE SEULE transaction I2C (1 START + 1 adresse + 6
; octets de donnees + 1 STOP) au lieu de 2: overhead START/adresse/
; STOP paye une seule fois pour tout l'octet (~2x plus rapide qu'un
; double appel a i2c_lcd_strobe, ~6x plus rapide que la toute
; premiere implementation a 6 transactions separees par octet -
; voir Directives.md). Jamais appele directement ailleurs que par
; i2c_lcd_command/i2c_lcd_data ci-dessous.
; Entree: AL = octet complet a transmettre. BL bit0 = RS voulu
; (0 = commande, I2C_LCD_RS = donnee).
; ============================================================
i2c_lcd_send_byte:
        push    ax
        push    bx
        push    cx
        push    dx

        mov     ch, al          ; CH = octet complet (commande/donnee)
        mov     dl, bl          ; DL = RS voulu - survit a la preparation
                                 ; des 2 quartets (voir i2c_write_byte,
                                 ; qui preserve integralement AX/BX/CX/DX)

        call    i2c_start
        mov     al, I2C_LCD_ADDR
        shl     al, 1
        call    i2c_write_byte

        ; --- quartet fort ---
        mov     al, ch
        and     al, 11110000b
        or      al, dl
        or      al, I2C_LCD_BL
        mov     bh, al          ; BH = octet PCF8574 de base (EN=0), quartet fort
        call    i2c_write_byte  ; EN=0
        mov     al, bh
        or      al, I2C_LCD_EN
        call    i2c_write_byte  ; EN=1
        mov     al, bh          ; EN=0 (capture du quartet fort)
        call    i2c_write_byte

        ; --- quartet faible ---
        mov     al, ch
        and     al, 00001111b
        mov     cl, 4
        shl     al, cl          ; quartet faible -> D4-D7
        or      al, dl
        or      al, I2C_LCD_BL
        mov     bh, al
        call    i2c_write_byte  ; EN=0
        mov     al, bh
        or      al, I2C_LCD_EN
        call    i2c_write_byte  ; EN=1
        mov     al, bh          ; EN=0 (capture du quartet faible)
        call    i2c_write_byte

        call    i2c_stop

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================
; i2c_lcd_command / i2c_lcd_data
; Envoient un octet complet au LCD I2C (voir i2c_lcd_send_byte),
; puis attendent le temps d'execution du HD44780 (reutilise
; lcd_delay de lib/lcd.asm - meme exigence, peu importe le transport).
; Entree: AL = octet a envoyer. lcd_command: RS=0. lcd_data: RS=1.
; ============================================================
i2c_lcd_command:
        push    bx
        mov     bl, 0
        call    i2c_lcd_send_byte
        pop     bx
        call    lcd_delay       ; reutilise lib/lcd.asm
        ret

i2c_lcd_data:
        push    bx
        mov     bl, I2C_LCD_RS
        call    i2c_lcd_send_byte
        pop     bx
        call    lcd_delay
        ret

; ============================================================
; i2c_lcd_print
; Affiche une chaine terminee par 00h (pas de padding). Entree: DS:SI.
; ============================================================
i2c_lcd_print:
        push    ax
        push    si
.next_char:
        mov     al, [si]
        cmp     al, 0
        je      .done
        call    i2c_lcd_data
        inc     si
        jmp     .next_char
.done:
        pop     si
        pop     ax
        ret

; ============================================================
; i2c_lcd_tx_hex_nibble / i2c_lcd_tx_hex_byte
; Affiche une valeur en hexadecimal majuscule. Generees par
; def_tx_hex_nibble/byte (lib/common.asm) - voir ce fichier pour la
; logique partagee avec lcd_tx_hex_* et uart_tx_hex_*.
;
; Positionnement DDRAM (i2c_lcd_line1..4/i2c_lcd_show_line1..4
; d'origine): voir les macros i2c_lcd_goto/i2c_lcd_show dans
; include/lcd_macros.inc.
; ============================================================
def_tx_hex_nibble i2c_lcd_tx_hex_nibble, i2c_lcd_data
def_tx_hex_byte   i2c_lcd_tx_hex_byte,   i2c_lcd_tx_hex_nibble
def_tx_hex_word   i2c_lcd_tx_hex_word,   i2c_lcd_tx_hex_byte

; ============================================================
; i2c_lcd_tx_dec3
; Affiche AX (0-999) en decimal, TOUJOURS 3 chiffres avec des zeros
; de tete (ex: 7 -> "007") - copie exacte de lcd_tx_dec3 (lib/lcd.asm),
; seule la procedure d'emission d'un caractere change (i2c_lcd_data au
; lieu de lcd_data). Detruit AX/BX/CX/DX - jamais SI/DI/ES/BP (meme
; discipline que lcd_tx_dec3/les routines hex).
; ============================================================
i2c_lcd_tx_dec3:
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
        call    i2c_lcd_data    ; centaines
        mov     al, bh
        add     al, '0'
        call    i2c_lcd_data    ; dizaines
        mov     al, ch
        add     al, '0'
        call    i2c_lcd_data    ; unites

        pop     dx
        pop     cx
        pop     bx
        ret

; ============================================================
; i2c_lcd_init
; Sequence d'initialisation standard HD44780 en mode 4 bits, via le
; PCF8574 I2C. Reutilise lcd_powerup_delay/lcd_delay_long/lcd_delay
; de lib/lcd.asm (memes exigences de timing HD44780).
; ============================================================
i2c_lcd_init:
        push    ax

        call    lcd_powerup_delay      ; >= 15-40ms apres mise sous tension

        mov     al, 00110000b          ; 0011b sur D4-D7
        call    i2c_lcd_strobe
        call    lcd_delay_long         ; >= 4,1ms

        mov     al, 00110000b
        call    i2c_lcd_strobe
        call    lcd_delay              ; >= 100us

        mov     al, 00110000b
        call    i2c_lcd_strobe
        call    lcd_delay

        mov     al, 00100000b          ; 0010b - bascule reellement en 4 bits
        call    i2c_lcd_strobe
        call    lcd_delay

        mov     al, 00101000b          ; Function Set: 4 bits, 2 lignes, police 5x8
        call    i2c_lcd_command

        mov     al, 00001100b          ; Display ON, curseur off, blink off
        call    i2c_lcd_command

        mov     al, 00000110b          ; Entry Mode: incremente, pas de decalage
        call    i2c_lcd_command

        mov     al, 00000001b          ; Clear Display
        call    i2c_lcd_command
        call    lcd_delay_long         ; Clear Display est plus lent (>= 1,52ms)

        pop     ax
        ret

%endif ; LCD_I2C_ASM
