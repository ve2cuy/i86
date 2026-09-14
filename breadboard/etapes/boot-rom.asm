; Project: 	8088 on a BreadBoard
; By:		VE2CUY 
; Date:		June 2010	
;-------------------------------------
; Description:  Stage 01: flash led's buffered by an 74LS373

.model tiny 

.data

i	db	0

.code 

;*****************
; CONST. PIO 1   *
;*****************
PORTA       EQU    01000000B   ;8255 ACTIVE PAR A6
PORTB       EQU    01000001B
PORTC       EQU    01000010B
PIO         EQU    01000011B
MASQUE_PIO  EQU    10000000B   ;PORT A,B ET C EN SORTIES
MASQUE_PIO2 EQU    10001001B   ;PORT A ET B EN SORTIES, C EN ENTREE

;*****************
; CONST. PIO 2   *
;*****************
PORT2A      EQU    00010000B   ;8255 no. 2 ACTIVE PAR A4
PORT2B      EQU    00010001B
PORT2C      EQU    00010010B
PIO2        EQU    00010011B
MASQUE_PIO2 EQU    10001001B   ;PORT A ET B EN SORTIES, C EN ENTREE


;*****************
; CONST. PIO 3   *
;*****************
PORT3A      EQU    00001000B   ;8255 no. 2 ACTIVE PAR A3
PORT3B      EQU    00001001B
PORT3C      EQU    00001010B
PIO3        EQU    00001011B
MASQUE_PIO3 EQU    10001001B   ;PORT A ET B EN SORTIES, C EN ENTREE


;****************************************
;* Debut du programme                   *
;****************************************

debut:

	
init:		;segments init
			xor		ax,ax	
			mov 	ds,ax		; place DS segment at begin of RAM
			
			mov		ax, 7ffh	; point to end of stack (end of 32k RAM)
			mov		ss, ax
			mov		sp, 0ffh		; stack length			

			call	init_8255
						
			mov ds:[100h], byte ptr 0
			;mov	i, 0

			
encore:		

			
;  ** move LED to LEFT 8 times
			mov		al,1
			mov		bx,16
effet1:		mov		cx, 8
			;mov al,byte ptr ds:[100h]   ; use memory as variable 
b2:			;out	0h, al					; any port to toggle the 74ls373
			
			ln
			
			call	proc1
			call	proc2
			call	proc3
			; inc byte ptr ds:[100h]

			call	delay2
			rcl		al,1			
			loop	b2

;  ** move LED to RIGHT 8 times
			mov		cx, 8
b3:			rcr		al,1			

			;out	0h, al					; any port to toggle the 74ls373
			
			call	proc1
			call	proc2
			call	proc3
			; inc byte ptr ds:[100h]

			call	delay2
			loop	b3

			dec		bx
			jnz		effet1

;*********************** ***********************


			call	clear_all_5255

			
			mov		bx, 8
effet2:		mov		cx, 7
			mov		al,1
b4:			;out	0h, al					; any port to toggle the 74ls373
			
			OUT    PORTA,AL
			call	delay
			rcl		al,1			
			loop	b4
			call	clear_8255A


;***********************
			mov		cx, 7
			mov		al,1
b5:			;out	0h, al					; any port to toggle the 74ls373
			
			OUT    PORTB,AL
			call	delay
			rcl		al,1			
			loop	b5
			call	clear_8255A


;***********************
			mov		cx, 7
			mov		al,1
b6:			;out	0h, al					; any port to toggle the 74ls373
			
			OUT    PORTC,AL
			call	delay
			rcl		al,1			
			loop	b6
			call	clear_8255A


;*********************** ***********************
			mov		cx, 7
			mov		al,1
b7:			;out	0h, al					; any port to toggle the 74ls373
			
			OUT    PORT2A,AL
			call	delay
			rcl		al,1			
			loop	b7
			call	clear_8255B

;***********************
			mov		cx, 7
			mov		al,1
b8:			;out	0h, al					; any port to toggle the 74ls373
			
			OUT    PORT2B,AL
			call	delay
			rcl		al,1			
			loop	b8
			call	clear_8255B


;***********************
			mov		cx, 7
			mov		al,1
b9:			;out	0h, al					; any port to toggle the 74ls373
			
			OUT    PORT2C,AL
			call	delay
			rcl		al,1			
			loop	b9
			call	clear_8255B


;*********************** ***********************
			mov		cx, 7
			mov		al,1
b10:		;	out	0h, al					; any port to toggle the 74ls373
			
			OUT    PORT3A,AL
			call	delay
			rcl		al,1			
			loop	b10
			call	clear_8255C

;***********************
			mov		cx, 7
			mov		al,1
b11:					
			OUT    PORT3B,AL
			call	delay
			rcl		al,1			
			loop	b11
			call	clear_8255C


;***********************
			mov		cx, 7
			mov		al,1
b12:					
			OUT    PORT3C,AL
			call	delay
			rcl		al,1			
			loop	b12
			call	clear_8255C

			dec		bx
			jnz		effet2



;***********************
effet3:		mov		cx,255
			mov		al,0
b20:			
			call	proc1
			call	proc2
			call	proc3
			call	delay2
			inc		al			
			loop	b20

			jmp	encore

;****************************************
;* Fin du programme                     *
;****************************************



;****************************************
;* Declaration des proc.                *
;****************************************


;****************************************
;* init 8255's			                *
;****************************************
init_8255:

         ;********************
          ;INIT LA 8255 NO. 1 *
          ;********************
          ;----------------------------------------
          ;LES 8255 SERVENT AU CONTROLE DUI CLAVIER
          ;ET DE L'ECRAN.
          ;----------------------------------------
          MOV    AL,MASQUE_PIO  ; PORT A,B ET C EN SORTIE
          OUT    PIO,AL         ; CMD LA 8255
          MOV    AL,0
          OUT    PORTA,AL
          OUT    PORTB,AL
          OUT    PORTC,AL

          ;********************
          ;INIT LA 8255 NO. 2 *
          ;********************
          MOV    AL,MASQUE_PIO  
          OUT    PIO2,AL        ; CMD LA 8255
          MOV    AL,0
          OUT    PORT2A,AL
          OUT    PORT2B,AL
          OUT    PORT2C,AL

          ;********************
          ;INIT LA 8255 NO. 3 *
          ;********************
          MOV    AL,MASQUE_PIO  
          OUT    PIO3,AL        ; CMD LA 8255
          MOV    AL,0
          OUT    PORT3A,AL
          OUT    PORT3B,AL
          OUT    PORT3C,AL

		ret


;****************************************
;* clear_all_5255.                     *
;****************************************
clear_all_5255:
			call	clear_8255A
			call	clear_8255B
			call	clear_8255C
			ret

;****************************************
;* clear_5255A..                        *
;****************************************

clear_8255A:
			push 	ax
			mov		al, 0
			call	proc1
			pop		ax
			ret
			   
;****************************************
;* clear_5255B..                        *
;****************************************
clear_8255B:
			push 	ax
			mov		al, 0
			call	proc2
			pop		ax
			ret

;****************************************
;* clear_5255C..                        *
;****************************************
clear_8255C:
			push 	ax
			mov		al, 0
			call	proc3
			pop		ax
			ret

;****************************************
;* proc1     ...                        *
;****************************************
proc1:		OUT    PORTA,AL			
			OUT    PORTB,AL			
			OUT    PORTC,AL			
			ret

;****************************************
;* proc2     ...                        *
;****************************************
proc2:		OUT    PORT2A,AL			
			OUT    PORT2B,AL			
			OUT    PORT2C,AL			
			ret

;****************************************
;* proc3     ...                        *
;****************************************
proc3:		OUT    PORT3A,AL			
			OUT    PORT3B,AL			
			OUT    PORT3C,AL			
			ret

;****************************************
;* wait a sec...                        *
;****************************************
delay:		push	dx
			push	bx
			mov 	bx,0999h 
boucle2:	dec 	bx
			jnz 	boucle2
			pop		bx
			pop		dx
			ret
;*** END delay

;****************************************
;* wait a sec...                        *
;****************************************
delay2:		push	dx
			push	bx
			mov 	bx,1FFFh 
boucle3:	dec 	bx
			jnz 	boucle3
			pop		bx
			pop		dx
			ret
;*** END delay

								
;****************************************
;* FIN - Declaration des proc.          *
;****************************************


			

;****************************************
;* CPU - start exec at 0FFFF0h			*
;****************************************
	org 3FF0h		; ROM = 32k
	jmp	debut
	db	'c2010a,VE2CUY'
;* 0FFFFh

	end	debut
	
