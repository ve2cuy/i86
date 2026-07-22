; ==========================================
; Ne fonctionne pas sous bochs

.MODEL TINY
.CODE
ORG 0

VGA_SEG     EQU     0B800h
ATTR_NORM   EQU     07h
CODE_BASE   EQU     0C000h      ; offset réel dans le segment F000 (ORG 0 = physique 0xFC000 = F000:C000)

POST:
    CLI
    XOR     AX, AX
    MOV     SS, AX
    MOV     SP, 7C00h

    MOV     AX, CS
    MOV     DS, AX

    DB      9Ah
    DW      0003h
    DW      0C000h

    MOV     AX, VGA_SEG
    MOV     ES, AX

    MOV     DI, 0
    MOV     SI, OFFSET MSG + CODE_BASE      ; correction manuelle de l'offset réel
    CALL    PrintString

    JMP     $

PrintString PROC
    PUSH    AX
PrintString_loop:
    MOV     AL, [SI]
    CMP     AL, 0
    JE      PrintString_done
    MOV     [ES:DI], AL
    MOV     BYTE PTR [ES:DI+1], ATTR_NORM
    ADD     DI, 2
    INC     SI
    JMP     PrintString_loop
PrintString_done:
    POP     AX
    RET
PrintString ENDP

MSG     DB      'Hello BIOS!', 0

ORG 3FF0h
Reset:
    DB      0EAh
    DW      0C000h
    DW      0F000h

ORG 3FF5h
    DB      '01/01/26', 0

ORG 3FFFh
    DB      0FFh

END