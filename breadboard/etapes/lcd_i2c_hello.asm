BITS    16
CPU     8086                    ; refuse tout opcode qui n'existe pas sur un vrai 8088
ORG     0000h                   ; = physique C0000h (debut de la ROM)

; ------------------------------------------------------------
; lcd_i2c_hello.asm
; ------------------------------------------------------------
; Pilote un LCD 2x16 via un module I2C (backpack PCF8574),
; adresse I2C 0x27, en "bit-banging" le protocole I2C sur 2 bits
; du port 10h (via le meme latch qu'avant).
;
; MAPPING DES BITS DU PORT 10h (a ajuster via les "equ" ci-dessous
; si le cablage reel differe):
;   bit 0 : SCL (horloge I2C)
;   bit 1 : SDA (donnee I2C)
;   bits 2-7 : non utilises
;
; MAPPING DES BROCHES DU PCF8574 (convention standard des
; backpacks LCD I2C - la meme que la bibliotheque LiquidCrystal_I2C
; utilise habituellement):
;   P0 : RS  (0=commande, 1=donnee)
;   P1 : R/W (toujours 0 - ecriture seule, comme avant)
;   P2 : E   (impulsion, front descendant = capture par le LCD)
;   P3 : retroeclairage (1 = allume, garde actif en permanence)
;   P4-P7 : D4-D7 (quartet de donnees)
;
; IMPORTANT - limite du "maitre I2C" implemente ici :
; Le latch du port 10h est une sortie push-pull classique, PAS a
; collecteur ouvert, et il n'y a aucun moyen de relire une broche.
; Ce programme est donc un maitre I2C "en ecriture seule, aveugle
; a l'ACK" : il envoie l'adresse et les octets sans jamais
; verifier l'accuse de reception de l'esclave. C'est une pratique
; courante pour piloter un PCF8574 en ecriture seule et ca
; fonctionne generalement bien, mais ce n'est pas un maitre I2C
; conforme a 100% de la specification.
; ------------------------------------------------------------
STACK_SEG       equ     1000h

I2C_SCL             equ     00000001b       ; bit0
I2C_SCL_MASK_OFF    equ     11111110b
I2C_SDA             equ     00000010b       ; bit1
I2C_SDA_MASK_OFF    equ     11111101b

LCD_I2C_ADDR        equ     027h            ; adresse 7 bits du module I2C

PCF_RS              equ     00000001b       ; P0
PCF_RW              equ     00000010b       ; P1 (jamais mis a 1 ici)
PCF_E               equ     00000100b       ; P2
PCF_BL              equ     00001000b       ; P3 (retroeclairage)

; Variable d'etat en RAM (le port 10h est en ecriture seule, donc
; on garde nous-memes une copie de la derniere valeur ecrite pour
; pouvoir modifier UN SEUL bit (SCL ou SDA) a la fois sans
; perturber l'autre). ES pointe sur le segment 0000h (RAM basse),
; DS reste sur CS pour lire les chaines de caracteres en ROM.
I2C_STATE_OFS       equ     0500h           ; offset arbitraire en RAM basse

start:
        cli
        mov     ax, STACK_SEG
        mov     ss, ax          ; SS = 1000h -> pile en fin de RAM (128K)
        mov     sp, 0000h
        sti

        mov     ax, cs
        mov     ds, ax          ; DS = CS: lit les chaines stockees dans la ROM

        xor     ax, ax
        mov     es, ax          ; ES = 0000h -> RAM basse, pour I2C_STATE
        mov     byte [es:I2C_STATE_OFS], 0

.ici:
        call    lcd_init

        mov     si, msg_line1
        call    lcd_print

        mov     al, 11000000b   ; "Set DDRAM Address" = 80h | 40h (debut ligne 2)
        call    lcd_command

        mov     si, msg_line2
        call    lcd_print

        mov     cx, 1000        ; laisse le texte visible 1000 ms
        call    delay_ms

        jmp     .ici            ; reboucle: reinit complete + reimpression

; ============================================================
; i2c_scl_high / i2c_scl_low / i2c_sda_high / i2c_sda_low
; Positionnent UN SEUL bit (SCL ou SDA) sans toucher a l'autre,
; en passant par la copie en RAM de l'etat courant du port.
; ============================================================
i2c_scl_high:
        push    ax
        mov     al, [es:I2C_STATE_OFS]
        or      al, I2C_SCL
        mov     [es:I2C_STATE_OFS], al
        out     10h, al
        call    i2c_delay
        pop     ax
        ret

i2c_scl_low:
        push    ax
        mov     al, [es:I2C_STATE_OFS]
        and     al, I2C_SCL_MASK_OFF
        mov     [es:I2C_STATE_OFS], al
        out     10h, al
        call    i2c_delay
        pop     ax
        ret

i2c_sda_high:
        push    ax
        mov     al, [es:I2C_STATE_OFS]
        or      al, I2C_SDA
        mov     [es:I2C_STATE_OFS], al
        out     10h, al
        call    i2c_delay
        pop     ax
        ret

i2c_sda_low:
        push    ax
        mov     al, [es:I2C_STATE_OFS]
        and     al, I2C_SDA_MASK_OFF
        mov     [es:I2C_STATE_OFS], al
        out     10h, al
        call    i2c_delay
        pop     ax
        ret

; ============================================================
; i2c_start / i2c_stop
; Conditions START (SDA descend pendant que SCL est haut) et
; STOP (SDA monte pendant que SCL est haut).
; ============================================================
i2c_start:
        call    i2c_sda_high
        call    i2c_scl_high
        call    i2c_sda_low
        call    i2c_scl_low
        ret

i2c_stop:
        call    i2c_sda_low
        call    i2c_scl_high
        call    i2c_sda_high
        ret

; ============================================================
; i2c_write_byte
; Envoie les 8 bits de AL, MSB en premier, un bit par front
; d'horloge SCL, puis genere un 9e front pour la place de l'ACK
; (ignore - impossible a relire avec ce montage).
; Entree: AL = octet a envoyer.
; ============================================================
i2c_write_byte:
        push    ax
        push    cx
        mov     ah, al          ; AH = copie de l'octet a envoyer
        mov     cl, 8
.bitloop:
        mov     al, ah
        and     al, 10000000b   ; teste le bit de poids fort
        cmp     al, 0
        je      .bit_zero
        call    i2c_sda_high
        jmp     .clock_it
.bit_zero:
        call    i2c_sda_low
.clock_it:
        call    i2c_scl_high
        call    i2c_scl_low
        shl     ah, 1           ; bit suivant (SHL reg,1 - seul decalage
                                 ; disponible sur un vrai 8086/8088)
        dec     cl
        jnz     .bitloop

        ; 9e front d'horloge - place de l'ACK, ignore (voir note en
        ; tete de fichier: ce maitre I2C ne peut pas relire SDA)
        call    i2c_sda_high
        call    i2c_scl_high
        call    i2c_scl_low

        pop     cx
        pop     ax
        ret

; ============================================================
; lcd_expander_write
; Ecrit UN octet complet sur les broches du PCF8574 (P0-P7), via
; une transaction I2C complete (START, adresse+ecriture, octet,
; STOP). Entree: AL = octet a placer sur les broches P0-P7.
; ============================================================
lcd_expander_write:
        push    ax
        mov     ah, al                          ; sauvegarde la donnee

        call    i2c_start

        mov     al, LCD_I2C_ADDR
        shl     al, 1                           ; adresse 7 bits -> bits7-1
        ; bit0 = R/W du bus I2C = 0 (ecriture)   -> deja 0 apres le SHL
        call    i2c_write_byte

        mov     al, ah
        call    i2c_write_byte

        call    i2c_stop

        pop     ax
        ret

; ============================================================
; lcd_strobe
; Envoie UN quartet deja pret (bits4-7 = donnee, bit0 = RS deja
; positionne par l'appelant). Ajoute toujours le retroeclairage
; (bit3), et genere l'impulsion E (bit2) via 3 ecritures
; successives: E=0 (repos), E=1, E=0 (front descendant = capture
; reelle par le LCD).
; Entree: AL = quartet (bits4-7) + RS (bit0), E et retroeclairage
; NE sont PAS positionnes par l'appelant.
; ============================================================
lcd_strobe:
        push    ax
        mov     ah, al
        or      ah, PCF_BL      ; retroeclairage toujours actif

        mov     al, ah
        call    lcd_expander_write     ; E=0 (etat de repos)

        mov     al, ah
        or      al, PCF_E
        call    lcd_expander_write     ; E=1

        mov     al, ah
        call    lcd_expander_write     ; E=0 -> le LCD capture ICI

        pop     ax
        ret

; ============================================================
; lcd_command / lcd_data
; Envoient un octet complet au LCD en 2 quartets (fort puis
; faible), chaque quartet place sur P4-P7. lcd_command: RS=0
; (P0=0). lcd_data: RS=1 (P0=1).
; Entree: AL = octet a envoyer. AH et CL sont utilises en interne.
; ============================================================
lcd_command:
        push    ax
        push    cx
        mov     ah, al          ; AH = copie de l'octet original

        mov     cl, 4
        mov     al, ah
        shr     al, cl          ; quartet fort dans les 4 bits de poids faible
        and     al, 00001111b
        shl     al, 1           ; deplace le quartet vers P4-P7 (4x SHL 1 -
        shl     al, 1           ; pas de SHL reg,imm sur un vrai 8086/8088)
        shl     al, 1
        shl     al, 1
        call    lcd_strobe      ; RS=0: rien a ajouter (bit0 deja a 0)

        mov     al, ah
        and     al, 00001111b   ; quartet faible
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        call    lcd_strobe

        pop     cx
        pop     ax
        call    lcd_delay
        ret

lcd_data:
        push    ax
        push    cx
        mov     ah, al

        mov     cl, 4
        mov     al, ah
        shr     al, cl
        and     al, 00001111b
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        or      al, PCF_RS      ; RS=1: c'est une donnee (caractere)
        call    lcd_strobe

        mov     al, ah
        and     al, 00001111b
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        or      al, PCF_RS
        call    lcd_strobe

        pop     cx
        pop     ax
        call    lcd_delay
        ret

; ============================================================
; lcd_init
; Sequence d'initialisation standard HD44780 en mode 4 bits,
; identique a la version parallele, mais chaque quartet passe
; maintenant par lcd_strobe (donc par I2C) au lieu d'un OUT
; direct.
; ============================================================
lcd_init:
        push    ax

        call    lcd_powerup_delay      ; >= 15-40ms apres mise sous tension

        mov     al, 0011b
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        call    lcd_strobe
        call    lcd_delay_long         ; >= 4.1ms

        mov     al, 0011b
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        call    lcd_strobe
        call    lcd_delay              ; >= 100us

        mov     al, 0011b
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        call    lcd_strobe
        call    lcd_delay

        mov     al, 0010b              ; bascule reellement en mode 4 bits
        shl     al, 1
        shl     al, 1
        shl     al, 1
        shl     al, 1
        call    lcd_strobe
        call    lcd_delay

        mov     al, 00101000b          ; Function Set: 4 bits, 2 lignes, police 5x8
        call    lcd_command

        mov     al, 00001100b          ; Display ON, curseur/clignotement OFF
        call    lcd_command

        mov     al, 00000110b          ; Entry Mode: incremente, pas de decalage
        call    lcd_command

        mov     al, 00000001b          ; Clear Display
        call    lcd_command
        call    lcd_delay_long         ; Clear Display est plus lent (>= 1.52ms)

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
; Delais
; ============================================================
i2c_delay:               ; largeur des phases SCL/SDA - marge large,
        push    bx        ; l'I2C tolere d'etre plus lent que 100kHz
        mov     bx, 0010h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_delay:                ; execution normale d'une commande/donnee
        push    bx
        mov     bx, 0200h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_delay_long:            ; Clear/Home et etapes du reveil 4 bits
        push    bx
        mov     bx, 4000h
.d:
        dec     bx
        jnz     .d
        pop     bx
        ret

lcd_powerup_delay:         ; >= 15-40ms apres mise sous tension
        push    cx
        mov     cx, 0020h
.rep:
        push    cx
        call    lcd_delay_long
        pop     cx
        loop    .rep
        pop     cx
        ret

; ============================================================
; delay_ms
; Delai en millisecondes (voir led_walk.asm pour la meme routine
; et son explication complete). Entree: CX = nombre de ms.
; ============================================================
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

; ---- messages -------------------------------------------------
msg_line1:      db      'Hello, World!', 0
msg_line2:      db      'I2C 0x27 OK', 0

; ---- remplissage jusqu'au vecteur de reset            ----
; ---- calcul en fonction de la taille de la ROM (256K) ----
; ---- A ajuster si la taille de la ROM change          ----
        times   03FFF0h - ($-$$) db 0FFh

reset_vector:
        jmp     0C000h:0000h    ; = physique FFFF0h -> saute vers START

db      ' VE2CUY 26'
; ---- remplissage jusqu'a la fin de la ROM (256K) ----
        times   040000h - ($-$$) db 0FFh
