.MODEL TINY
.CODE
ORG 0
    JMP     POST
VGA_SEG     EQU     0B800h      ; segment du buffer VGA (mode texte)
ATTR_NORM   EQU     07h         ; gris clair sur noir

;==========================================
; Point d'entrée réel du BIOS (POST)
;==========================================
POST:
    CLI
    MOV     AX, CS
    MOV     DS, AX
    MOV     SS, AX
    MOV     SP, 0FFFEh

    ; Initialiser la carte VGA en appelant son BIOS d'extension
    ; CALL    0C000h:0003h
    ; CALL FAR 0C000h:0003h (encodage manuel)
    DB      9Ah                 ; opcode CALL FAR ptr16:16
    DW      0003h               ; offset cible
    DW      0C000h              ; segment cible

    
    ; Pointer ES vers le segment du buffer VGA
    MOV     AX, VGA_SEG
    MOV     ES, AX

    ; Afficher notre message à l'écran (ligne 0, colonne 0)
    MOV     DI, 0                   ; offset de départ = (0*80+0)*2 = 0
    MOV     SI, OFFSET MSG
    CALL    PrintString

    JMP     $                       ; boucle infinie (halte)

;==========================================
; PrintString : affiche une chaîne DS:SI
; terminée par 0, à partir de ES:DI
;==========================================
PrintString:
    PUSH    AX
next_char:
    MOV     AL, [SI]                ; charge le caractère
    CMP     AL, 0                   ; fin de chaîne ?
    JE      done_print
    MOV     [ES:DI], AL             ; écrit le caractère
    MOV     BYTE PTR [ES:DI+1], ATTR_NORM  ; écrit l'attribut
    ADD     DI, 2                   ; avance de 2 octets (1 caractère)
    INC     SI
    JMP     next_char
done_print:
    POP     AX
    RET

MSG     DB      'Hello BIOS!', 0

;==========================================
; Vecteur de reset : offset 0x3FF0
; = adresse physique 0xFFFF0
;==========================================
ORG 3FF0h
Reset:
    DB      0EAh                ; opcode JMP FAR ptr16:16
    DW      0C000h              ; offset cible = F000:C000 (valeur littérale, PAS "OFFSET POST")
    DW      0F000h              ; segment cible


ORG 3FB0h
    DB      'Par Alain Boudreault - VE2CUY (c) 2026', 0
    DB      '21/07/26', 0


ORG 3FFFh
    DB      0FFh

END