; Pour compiler le programme, utilisez la commande suivante :
; ..\..\bin\JWasm.exe -bin -Fo  .\print_with_21h.com  .\print_with_21h.asm

; Utiliser DOSBox-X pour exécuter le programme .com généré.
.MODEL TINY
.CODE
ORG 100h

START:
    ; Afficher le message "Hello World!" à l'écran en utilisant l'interruption 21h
    MOV     AH, 09h
    MOV     DX, OFFSET MSG
    INT     21h

    ; Retourner le contrôle à DOS
    MOV     AH, 4Ch
    INT     21h

MSG DB 'Hello World via interrupt 21h, service 09h!$'

END START