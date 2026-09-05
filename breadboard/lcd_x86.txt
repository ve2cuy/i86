; HD44780 initialization for x86 real mode asm.
; Should compile with any x86 in real mode.
; Origianlly tested with 80C188

; The application uses 8 bit data bus to 
; access the LCD in 4-bit mode. 
; Bit 5 controls D/C
; R/W is done using buss access pins.

per_lcd     equ ep_pcs1+0x40            ; LCD IO port

; Delay loop; Wait a bit more than 1 us on 10 MHz sys clock
; A lot overhead in instr fetch
wait_us:
	shr ax, 1
	.loop:
	dec ax
	jnz .loop
	ret 

; Initialize HD44780 LCD
init_lcd:
	outp    per_lcd, 0x03
	mov     ax, 4100
	call    wait_us
	outp    per_lcd, 0x03
	mov     ax, 100
	call    wait_us
	outp    per_lcd, 0x03
	mov     ax, 100
	call    wait_us
	outp    per_lcd, 0x02
	mov     ax, 100
	call    wait_us

	; In 4 bit mode
	mov     ax, 0x28
	call    cmd_lcd

	mov     ax, 0x08
	call    cmd_lcd
	mov     ax, 0x01
	call    cmd_lcd
	mov     ax, 4000
	call    wait_us

	mov     ax, 0x06
	call    cmd_lcd
	mov     ax, 0x0f
	call    cmd_lcd
	
	ret

; Print ch LCD
putch_lcd:
	push bx
	push cx
	mov cx, ax
	mov bx, ax
	shr bx, 4
	and bl, 0x0F
	or bl, 0x10
	outp per_lcd, bl
	mov bx, cx
	and bl, 0x0F
	or bl, 0x10
	outp per_lcd, bl
	mov ax, 53
	call wait_us
	pop cx
	pop bx
	ret

; Issue a command to LCD
cmd_lcd:
	push bx
	push cx
	mov cx, ax
	mov bx, ax
	shr bx, 4
	and bl, 0x0F
	outp per_lcd, bl
	mov bx, cx
	and bl, 0x0F
	outp per_lcd, bl
	mov ax, 53
	call wait_us
	pop cx
	pop bx
	ret