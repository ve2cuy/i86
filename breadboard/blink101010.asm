; ==============================================
; Boot ROM 8088 - 256K, mappée en C0000h-FFFFFh
; ----------------------------------------------
; Testes de la carte breadboard avec un 
; clignotement d'une LED sur le port 10h
; La vitesse d'horloge est de 5,33 MHz (XT)
; À Quelle fréquence clignote la LED ?
; ==============================================

MODEL	SMALL

.8086
.stack
.code
extern _main:near
.startup
        cli		       ; interrupt disable
	call  near ptr _main
endless:
	jmp   endless
.data


.MODEL SMALL
.8086
.stack
.CODE
.startup
; ORG     0000h          ; = physique C0000h (début de la ROM)

START:
        MOV     AL, 0AAh       ; AL = 10101010b
        OUT     10h, AL        ; envoie AL sur le port 10h

        MOV     BX, 0000h      ; compteur de délai
DELAI1:
        DEC     BX
        JNZ     DELAI1

        MOV     AL, 00h        ; AL = 00000000b
        OUT     10h, AL

        MOV     BX, 0000h
DELAI2:
        DEC     BX
        JNZ     DELAI2

        JMP     START          ; boucle infinie


; ---------- NOTE
; Ce code sera injecté par le script python
; py .\make-rom256k.py .\blink101010.bin
; Nécessaire car le EEPROM est suppérieure à 64Ko.  C"est une limitation du 8088 qui ne peut adresser que 64Ko à la fois.  Le vecteur de reset doit donc être placé à l'adresse physique FFFF0h (segment C000h, offset 0FFF0h) pour que le processeur puisse démarrer correctement.     
;        ORG     03FFF0h         ; = physique FFFF0h (vecteur de reset)
        
;RESET_VECTOR:
;        ; JMP     0C000h:0000h   ; saute vers START
;        DB      0EAh            ; opcode JMP FAR (direct)
;        DW      0000h           ; offset  = 0000h
;        DW      0C000h          ; segment = C000h        

.data
        DB      ' VE2CUY 26'        
END

; C:\Users\alin_\AppData\Local\Temp\VSM Studio\abd27828c0b64cec9bc472d8fc464420\8086\Debug\Debug.exe
