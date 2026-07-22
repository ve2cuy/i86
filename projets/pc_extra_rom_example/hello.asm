; https://github.com/Baron-von-Riedesel/JWasm/releases#release-v2.20
; ..\JWasm.exe -bin .\hello.asm -Fo .\hello.com

CSEG SEGMENT
        ASSUME  CS:CSEG, DS:CSEG

        ORG     100h

START:
        MOV     AH, 09h
        MOV     DX, OFFSET MSG
        INT     21h

        MOV     AH, 4Ch
        INT     21h

MSG     DB      'Hello World!',10,13,'Ici la voix des misterons!',10,13,'$'

CSEG    ENDS
        END     START
