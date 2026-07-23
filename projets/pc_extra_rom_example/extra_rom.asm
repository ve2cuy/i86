; ====================================================
; Exemple d'un BIOS d'extension (Option ROM) pour PC
; ====================================================
;  .\build_rom.bat .\extra_rom
; 
; À tester sous bochs avec la commande 
; $Env:PATH += ";C:\Program Files\Bochs-3.0\"
; bochs -f bochsrc.bxrc -q
; ----------------------------------------------------
; M-A-J: 2026.07.22
; ----------------------------------------------------

.MODEL TINY
.CODE
ORG 0

; -----------------------------------------------------
; Les constantes
ROM_SIZE_BLOCKS     EQU 4          ; taille = 4 * 512 = 2048 octets (ajustez selon votre taille réelle)
; ATTR_NORM           EQU     07h    ; gris clair sur noir

; -----------------------------------------------------
; Les macros
PRINT_AT MACRO msg_offset, row, col, attr
    MOV     DI, (row*80+col)*2
    MOV     SI, msg_offset
    MOV     AH, attr
    CALL    PrintString
ENDM

DEFATTR MACRO name, fg, bg
name = (bg SHL 4) OR fg
ENDM

DEFATTR ATTR_NORM,  07h, 00h    ; gris clair sur noir
DEFATTR ATTR_ALERT, 0Eh, 04h    ; jaune sur rouge
DEFATTR ATTR_OK,    0Ah, 00h    ; vert sur noir


; -----------------------------------------------------
; Signature et point d'entrée d'un BIOS d'extension (Option ROM)
Signature:
    DB      55h, 0AAh                  ; offset 0-1 : signature
    DB      ROM_SIZE_BLOCKS            ; offset 2 : taille en blocs de 512 octets

EntryPoint:                            ; offset 3 : point d'entrée obligatoire
    ; Votre code d'initialisation ici
    ; Par convention : le BIOS appelle ce point en CALL FAR,
    ; donc terminez par un RETF (RET FAR), pas un JMP $ !

    PUSH    AX
    PUSH    DS
    PUSH    ES

    MOV     AX, CS              ; ← AJOUT : récupère le segment courant (D000h)
    MOV     DS, AX              ; ← AJOUT : DS = CS, cohérent avec OFFSET MSG

    ; ... votre code d'affichage VGA ...
    MOV     AX, 0B800h
    MOV     ES, AX
    CALL    Cls                     ; efface l'écran
    ;MOV     DI, 0
    ;MOV     SI, OFFSET MSG
    ;CALL    PrintString
    PRINT_AT OFFSET MSG, 10, 20, ATTR_OK
    PRINT_AT OFFSET MSG_ROUGE, 12, 10, ATTR_ALERT

    POP     ES
    POP     DS
    POP     AX
    JMP     $            ; temporairement, boucle infinie pour éviter de retourner au BIOS appelant
    ; RETF                                ; retour au BIOS appelant (obligatoire !)

PrintString PROC
    PUSH    AX
PrintString_loop:
    MOV     AL, [SI]
    CMP     AL, 0
    JE      PrintString_done
    MOV     [ES:DI], AL
    MOV     BYTE PTR [ES:DI+1], AH
    ADD     DI, 2
    INC     SI
    JMP     PrintString_loop
PrintString_done:
    POP     AX
    RET
PrintString ENDP

;-----------------------------------------------------
;==========================================
; Cls : efface l'écran (remplit de 80x25
; espaces avec l'attribut par défaut) et
; replace le curseur en 0,0
; Suppose ES déjà pointé vers 0B800h
;==========================================
Cls PROC
    PUSH    AX
    PUSH    CX
    PUSH    DI

    MOV     DI, 0
    MOV     CX, 80*25           ; 2000 caractères à effacer
    MOV     AH, ATTR_NORM       ; attribut (ex: 07h)
    MOV     AL, ' '             ; caractère espace
Cls_loop:
    MOV     [ES:DI], AX         ; écrit AL (caractère) + AH (attribut) d'un coup
    ADD     DI, 2
    LOOP    Cls_loop

    POP     DI
    POP     CX
    POP     AX
    RET
Cls ENDP


MSG         DB      'Hello depuis Option ROM!', 0
MSG_ROUGE   DB      'Je suis un message JAUNE sur fond ROUGE ;-)', 0


    ; Padding jusqu'à la taille totale déclarée, moins 1 octet pour le checksum
    ORG     (ROM_SIZE_BLOCKS * 512) - 1
Checksum:
    DB      0                           ; placeholder, à calculer après compilation

END