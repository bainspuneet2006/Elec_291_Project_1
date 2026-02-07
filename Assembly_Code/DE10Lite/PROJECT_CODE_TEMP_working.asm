; ISR_example_DE10Lite.asm:
; a) Increments/decrements a BCD variable every half second using
;    an ISR for timer 2.  Uses SW0 to decide.  Also 'blinks' LEDR0 every
;    half second.
; b) Generates a 2kHz square wave at pin P1.5 using an ISR for timer 0.
; c) In the 'main' loop it displays the variable incremented/decremented
;    using the ISR for timer 2 on the LCD and the 7-segment displays.
;    Also resets it to zero if the KEY1 pushbutton  is pressed.
; d) Controls the LCD using general purpose pins P2.3, P2.5, P2.7, P3.1, P3.3, P3.5, P3.7
;
; FIXES ADDED:
;   1) Stack pointer moved off 0x7F -> 0x60 (0x7F causes pushes into SFR space at 0x80+)
;   2) Removed cpl P1.1 inside Timer2 ISR (P1.1 is LCD E pin, was being toggled every 1ms)
;   3) Timer2 ISR now saves/restores B, DPL, DPH too (prevents random corruption w/ math/LCD)
;   4) Serial: setb TI after init, and a more standard putchar (wait TI, clr TI, write SBUF)
;
$NOLIST
$MODMAX10
$LIST


CLK           EQU 33333333 ; Microcontroller system crystal frequency in Hz
TIMER0_RATE   EQU 4096     ; 2048Hz squarewave (peak amplitude of CEM-1203 speaker)
TIMER0_RELOAD EQU ((65536-(CLK/(12*TIMER0_RATE)))) ; The prescaler in the CV-8052 is always 12 unlike the N76E003 where is selectable.
TIMER2_RATE   EQU 1000     ; 1000Hz, for a timer tick of 1ms
TIMER2_RELOAD EQU ((65536-(CLK/(12*TIMER2_RATE))))

SOUND_OUT     equ P1.5
UPDOWN        equ SWA.0
Play_beeps_Switch equ SWA.1
Start_Switch equ SWA.2

;-------I dont know which pin we are connecting to 
; the SSR box so we can change this accordingly
; [important] if we change that we also need to change
; P2MOD accordinlgy
SSR_PIN equ P2.0 

; Unfortunately the maximum baurate we can use with timer 1 is 57600
; so make sure you configure putty/matlab/python accordingly.
BAUD            EQU 57600
TIMER_1_RELOAD  EQU (256-((2*CLK)/(12*32*BAUD)))

; The Special Function Registers below were added to 'MODMAX10' recently.
; If you are getting an error, uncomment the three lines below.

;ADC_C DATA 0A1h
;ADC_L DATA 0A2h
;ADC_H DATA 0A3h

; Reset vector
org 0x0000
    ljmp main

; External interrupt 0 vector (not used in this code)
org 0x0003
	reti

; Timer/Counter 0 overflow interrupt vector
org 0x000B
	ljmp Timer0_ISR

; External interrupt 1 vector (not used in this code)
org 0x0013
	reti

; Timer/Counter 1 overflow interrupt vector (not used in this code)
org 0x001B
	reti

; Serial port receive/transmit interrupt vector (not used in this code)
org 0x0023
	reti

; Timer/Counter 2 overflow interrupt vector
org 0x002B
	ljmp Timer2_ISR


; In the 8051 we can define direct access variables starting at location 0x30 up to location 0x7F
dseg at 0x30
Count1ms:     ds 2 ; Used to determine when half second has passed
count_ms:     ds 2 ; For determining when a full second has passed

BCD_counter:  ds 1 ; The BCD counter incrememted in the ISR and displayed in the main loop
beep_count: ds 1
beep_state: ds 1
FSM1_state: ds 1
temp_soak: ds 1
Time_soak: ds 1
Temp_refl: ds 1
Time_refl: ds 1
pwm_counter: ds 1
pwm: ds 1
temp: ds 1 
sec: ds 1
x : ds 4
y : ds 4
bcd : ds 5

V_amp_mv: ds 4
V_unamp: ds 4
T_cold: ds 4
t_hot : ds 4
VAL_LM4040: ds 2




; In the 8051 we have variables that are 1-bit in size.  We can use the setb, clr, jb, and jnb
; instructions with these variables.  This is how you define a 1-bit variable:
bseg
half_seconds_flag: dbit 1 ; Set to one in the ISR every time 500 ms had passed
mf : dbit 1
Reached50_flag: dbit 1     ; NEW: set once temperature >= 50C during first 60s

cseg
; These 'equ' must match the wiring between the DE10Lite board and the LCD!
; P0 is in connector JPIO.  Check "CV-8052 Soft Processor in the DE10Lite Board: Getting
; Started Guide" for the details.
ELCD_RS equ P1.7
; ELCD_RW equ Px.x ; Not used.  Connected to ground
ELCD_E  equ P1.1
ELCD_D4 equ P0.7
ELCD_D5 equ P0.5
ELCD_D6 equ P0.3
ELCD_D7 equ P0.1

InitialString: db '\r\nHello, World!\r\n', 0
$NOLIST
$include(LCD_4bit_DE10Lite_no_RW.inc) ; A library of LCD related functions and utility macros
$include(math32.inc)
$LIST


;                     1234567890123456    <- This helps determine the location of the counter
Initial_Message:  db 'TempC= xx ', 0

; Optional: label for serial output
TempLabel: db 'TempC=',0


;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 0                     ;
;---------------------------------;
Timer0_Init:
	mov a, TMOD
	anl a, #0xf0 ; Clear the bits for timer 0
	orl a, #0x01 ; Configure timer 0 as 16-timer
	mov TMOD, a
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)
	; Enable the timer and interrupts
    setb ET0  ; Enable timer 0 interrupt
    clr TR0  ; Start timer 0
	ret

;---------------------------------;
; ISR for timer 0.  Set to execute;
; every 1/4096Hz to generate a    ;
; 2048 Hz square wave at pin P3.7 ;
;---------------------------------;
Timer0_ISR:
	;clr TF0  ; According to the data sheet this is done for us already.
	mov TH0, #high(TIMER0_RELOAD) ; Timer 0 doesn't have autoreload in the CV-8052
	mov TL0, #low(TIMER0_RELOAD)
	cpl SOUND_OUT ; Connect speaker to P3.7!
	reti


;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 2                     ;
;---------------------------------;
Timer2_Init:
	mov T2CON, #0 ; Stop timer/counter.  Autoreload mode.
	mov TH2, #high(TIMER2_RELOAD)
	mov TL2, #low(TIMER2_RELOAD)
	; Set the reload value
	mov RCAP2H, #high(TIMER2_RELOAD)
	mov RCAP2L, #low(TIMER2_RELOAD)
	; Init One millisecond interrupt counter.  It is a 16-bit variable made with two 8-bit parts
	clr a
	mov Count1ms+0, a
	mov Count1ms+1, a
	; Enable the timer and interrupts
    setb ET2  ; Enable timer 2 interrupt
    setb TR2  ; Enable timer 2
	ret



Timer2_ISR:
    clr TF2   ; Timer 2 doesn't clear TF2 automatically
    push acc
    push psw
    push b
    push dpl
    push dph

    ; --- PWM LOGIC ---
    inc pwm_counter
    mov a, pwm_counter
    cjne a, #100, do_pwm_check
    mov pwm_counter, #0

do_pwm_check:
    clr c
    mov a, pwm_counter
    subb a, pwm
    jc turn_ssr_on

turn_ssr_off:
    setb SSR_PIN       ; Turn OFF (Active Low logic: 1=OFF)
    sjmp pwm_done

turn_ssr_on:
    clr SSR_PIN        ; Turn ON (Active Low logic: 0=ON)

pwm_done:
    ; --- TIME KEEPING ---
    inc Count1ms+0
    mov a, Count1ms+0
    jnz Inc_High
    inc Count1ms+1
Inc_High:

    inc count_ms+0
    mov a, count_ms+0
    jnz Inc_High_2
    inc count_ms+1
Inc_High_2:

    ; Check 1000ms (1 Second)
    mov a, count_ms+0
    cjne a, #low(1000), Check_500ms
    mov a, count_ms+1
    cjne a, #high(1000), Check_500ms

    ; 1 Second passed
    inc sec            ; Update FSM timer
    clr a
    mov count_ms+0, a  ; Reset MS counter
    mov count_ms+1, a

Check_500ms:
    mov a, Count1ms+0
    cjne a, #low(500), beep_logic
    mov a, Count1ms+1
    cjne a, #high(500), beep_logic

    ; 500ms passed
    clr a
    mov Count1ms+0, a
    mov Count1ms+1, a
    setb half_seconds_flag
    cpl LEDRA.0

    ; --- BEEP LOGIC --

    mov a, beep_count
    jz beep_logic
    dec beep_count
    
beep_logic: 
	mov a, beep_count
	jz stop_beeping

    mov a, Count1ms+1
    jnz stop_beeping
    mov a, Count1ms+0
    cjne a, #100, check_less
    sjmp stop_beeping
    
check_less:
	jnc stop_beeping

turn_beep_on_logic:
    setb TR0
    sjmp beep_logic_done

stop_beeping:
    clr TR0
    clr SOUND_OUT
    

beep_logic_done:
    ; --- BCD COUNTER ---
    mov a, BCD_counter
    jb UPDOWN, Timer2_ISR_decrement
    add a, #0x01
    da a
    mov BCD_counter, a
    sjmp Timer2_ISR_done_jump

Timer2_ISR_decrement:
    add a, #0x99
    da a
    mov BCD_counter, a

Timer2_ISR_done_jump:
    pop dph
    pop dpl
    pop b
    pop psw
    pop acc
    reti

; Look-up table for the 7-seg displays. (Segments are turn on with zero)
T_7seg:
    DB 0xC0, 0xF9, 0xA4, 0xB0, 0x99        ; 0 TO 4
    DB 0x92, 0x82, 0xF8, 0x80, 0x90        ; 4 TO 9
    DB 0x88, 0x83, 0xC6, 0xA1, 0x86, 0x8E  ; A to F





;---------------------------------;
; FSM code here. I defined FSM1_state, 
; temp_soak, Time_soak, Time_refl, Temp_refl
; so use those in your code when you need to. ALso 
; in the code im pretty sure pwm is the amount of power 
; passed to the SSR so use that 
;-----------------------------------;
FSM1: 
	mov a, FSM1_state
	
FSM_state0:
	cjne a, #0, FSM1_state1
	mov pwm, #0
	jb Start_Switch, FSM1_state0_done
	;jnb PB6, $
	lcall playSingle_beep
	mov sec, #0            ; start timing "first 60 seconds"
    clr Reached50_flag
	mov FSM1_state, #1
	
	
FSM1_state0_done:
;-----note that here FSM2 is another 'FSM' or loop we run so it 
; can be something like updating the LCD display and stuff like that
; I renamed the main loop to FSM2 so itll go there and come back
	ljmp FSM2
	
FSM1_state1:
	cjne a, #1, FSM1_state2
	mov pwm, #100

; -------------------------------
    ; SAFETY ABORT (Lab requirement):
    ; Abort if NOT >=50C within 60s
    ; -------------------------------

    ; If temp >= 50C, latch the flag
    mov a, temp
    clr c
    subb a, #50
    jc  temp_below_50
    setb Reached50_flag

temp_below_50:
    ; If sec >= 60 and we never reached 50C -> ERROR
    mov a, sec
    clr c
    subb a, #60
    jc  continue_preheat          ; sec < 60, keep going
    jb  Reached50_flag, continue_preheat

    ; ---- ABORT ----
    mov pwm, #0
    mov FSM1_state, #6             ; ERROR state (new)
    lcall ten_beeps                ; required error beeps
    ljmp FSM2

continue_preheat:
    ; -------- existing logic to go to SOAK when temp reaches temp_soak -----
    mov a, temp_soak
    clr c
    subb a, temp
    jnc FSM1_state1_done
    mov FSM1_state, #2
    lcall playSingle_beep
	
FSM1_state1_done:
	
	ljmp FSM2
	
FSM1_state2:
	cjne a, #2, FSM1_state3
	mov pwm, #20
	mov a, time_soak
	clr c
	; ------------clarify if this is where we store the time passed-----;
	; yes it is i defined it --
	subb a, sec
	jnc FSM1_state2_done
	mov FSM1_state, #3
	;state switch
	lcall playSingle_beep
	
FSM1_state2_done:

	ljmp FSM2
	
	
FSM1_state3:
	cjne a, #3, FSM1_state4
	mov pwm, #100
	mov sec, #0
	mov a, temp_refl
	clr c
	subb a, temp
	jnc FSM1_state3_done
	mov FSM1_state, #4
	lcall playSingle_beep
	
FSM1_state3_done:
	ljmp FSM2
	
FSM1_state4:
	cjne a, #4, FSM1_state5
	mov pwm, #20
	mov a, time_refl
	clr c
	subb a, sec
	jnc FSM1_state4_done
	mov FSM1_state, #5
	
	lcall playSingle_beep
	
FSM1_state4_done:
ljmp FSM2


FSM1_state5:
	cjne a, #5, FSM1_state0
	mov pwm, #0
	mov a, temp
	clr c
	subb a, #60
	
	
	jnc FSM_state5_done
	mov FSM1_state, #0
	
FSM_state5_done: 
ljmp FSM2

FSM1_state6:
    cjne a, #6, FSM_state0     ; if not error, go back to normal dispatcher
    mov pwm, #0                ; force oven OFF

    ; Stay here until the START switch is released (Start_Switch = 1)
    ; (Your Start_Switch appears active-low because state0 uses "jb Start_Switch")
    jb Start_Switch, _err_to_idle
    ljmp FSM2                  ; keep waiting

FSM_state6_done:
    mov FSM1_state, #0          ; return to idle
    ljmp FSM2

	
	
; -------Other FSM states can go here-------

;---------------------------------;
; Main program. Includes hardware ;
; initialization and 'forever'    ;
; loop.                           ;
;---------------------------------;
main:
	; Initialization
    ; FIX: SP MUST NOT BE 0x7F for this big program (interrupts + LCD + math).
    ; Put stack above your variables but still below 0x7F.
    mov SP, #0x60
    ; initialise state 0
    mov FSM1_state, #0

    lcall Timer0_Init
    lcall Timer2_Init
	lcall Initialize_Serial_Port

    ; We use the pins of P0 to control the LCD.  Configure as outputs.
    mov P0MOD, #10101010b ; P0.1, P0.3, P0.5, P0.7 are outputs.  ('1' makes the pin output)
    ; We use pins P1.5 and P1.1 as outputs also.  Configure accordingly.
    mov P1MOD, #10100010b ; P1.7 and P1.1 are outputs
    mov P2MOD, #0xff
    mov P3MOD, #0xff

    ; Turn off all the LEDs
    mov LEDRA, #0 ; LEDRA is bit addressable
    mov LEDRB, #0 ; LEDRB is NOT bit addresable

    setb EA   ; Enable Global interrupts

    lcall ELCD_4BIT ; Configure LCD in four bit mode

    ; For convenience a few handy macros are included in 'LCD_4bit_DE1Lite.inc':
	Set_Cursor(1, 1)
    Send_Constant_String(#Initial_Message)
    setb half_seconds_flag
	mov BCD_counter, #0x00 ; Initialize counter to zero

    mov T_cold+0, #098h   ; 2200 low byte
    mov T_cold+1, #008h   ; 2200 high byte
    mov T_cold+2, #000h
    mov T_cold+3, #000h
	mov ADC_C, #080h ; Reset ADC
	Wait_Milli_Seconds(#50)

	; After initialization the program stays in this 'forever' loop
FSM2:


;testing to playbeeps when switch is on. Replace this in fsm. call functions for 1, 5 or 10 beeps 
jnb Play_beeps_Switch, skip_beep
jnb half_seconds_flag, skip_beep
lcall playSingle_beep

skip_beep:
	jb KEY.1, loop_a  ; if the KEY1 button is not pressed skip
	Wait_Milli_Seconds(#50)	; Debounce delay.  This macro is also in 'LCD_4bit_DE1Lite.inc'
	jb KEY.1, loop_a  ; if the KEY1 button is not pressed skip
	jnb KEY.1, $		; Wait for button release.  The '$' means: jump to same instruction.
	; A valid press of the 'BOOT' button has been detected, reset the BCD counter.
	; But first stop timer 2 and reset the milli-seconds counter, to resync everything.
	clr TR2 ; Stop timer 2
	clr a

	mov Count1ms+0, a
	mov Count1ms+1, a
	; Now clear the BCD counter
	mov BCD_counter, a
	setb TR2    ; Start timer 2
	sjmp loop_b ; Display the new value
loop_a:
	jnb half_seconds_flag, loop
loop_b:
    clr half_seconds_flag ; We clear this flag in the main loop, but it is set in the ISR for timer 2

	    ; the place in the LCD where we want the BCD counter value
	; Also display the counter using the 7-segment displays.

	lcall Read_Ref
	lcall Read_op_amp_mv
	;lcall PrintHex32_Vamp
	;lcall send_adc_debug
	lcall VoutmV_To_TempC
	Set_Cursor(1,7)
	lcall Display_TempC_7seg
	;mov t_cold, #0x01
	;mov t_hot, #0xff
	; now we need to print the temp to hex display and send it to the serial monitor
	lcall send_temp_serial
	

    ljmp FSM1


;SUBROUTINES HERE

; =======================================================
; Display_TempC_7Seg
; Displays temperature (integer °C) on HEX2 HEX1 HEX0
; Uses:
;   t_hot  = centi-°C (°C*100)  [already computed in VoutmV_To_TempC]
;   math32 div32 (x = x/y)
; Reuses T_7seg table (0..9)
; =======================================================
Display_TempC_7Seg:
    push acc
    push b
    push dpl
    push dph

    ; x = t_hot (centi-°C)
    mov x+0, t_hot+0
    mov x+1, t_hot+1
    mov x+2, t_hot+2
    mov x+3, t_hot+3

    ; x = x / 100  -> integer °C
    Load_y(100)
    lcall div32              ; x now = integer °C

    ; Copy integer temp to R3:R4 (16-bit is enough)
    mov R4, x+0
    mov R3, x+1

    ; -------------------------
    ; Compute hundreds in R2
    ; -------------------------
    mov R2, #0               ; hundreds

DT_Hund_Loop:
    ; if (R3:R4) < 100 stop
    mov a, R3
    jnz DT_Hund_Sub
    mov a, R4
    clr c
    subb a, #100
    jc  DT_Hund_Done

DT_Hund_Sub:
    ; (R3:R4) -= 100
    mov a, R4
    clr c
    subb a, #100
    mov R4, a
    mov a, R3
    subb a, #0
    mov R3, a
    inc R2
    sjmp DT_Hund_Loop

DT_Hund_Done:
    ; Now R2 = hundreds (0..9), remaining value in R4 is 0..99

    ; tens/ones from remaining
    mov a, R4
    mov b, #10
    div ab                   ; A=tens (0..9), B=ones (0..9)
    mov R1, A                ; tens
    mov R0, B                ; ones

    ; -------------------------
    ; Map digits to 7-seg and write HEX2..HEX0
    ; -------------------------
    mov dptr, #T_7seg

    ; ones -> HEX0
    mov a, R0
    movc a, @a+dptr
    mov HEX0, a

    ; tens -> HEX1 (blank if hundreds=0 and tens=0)
    mov a, R2
    jnz DT_Show_Tens
    mov a, R1
    jnz DT_Show_Tens
    mov HEX1, #0FFh
    sjmp DT_Do_Hund

DT_Show_Tens:
    mov a, R1
    movc a, @a+dptr
    mov HEX1, a

DT_Do_Hund:
    ; hundreds -> HEX2 (blank if 0)
    mov a, R2
    jnz DT_Show_Hund
    mov HEX2, #0FFh
    sjmp DT_Done

DT_Show_Hund:
    mov a, R2
    movc a, @a+dptr
    mov HEX2, a

DT_Done:
    pop dph
    pop dpl
    pop b
    pop acc
    ret
; Displays a BCD number in HEX1-HEX0


Initialize_Serial_Port:
	; Configure serial port and baud rate
	clr TR1 ; Disable timer 1
	anl TMOD, #0x0f ; Mask the bits for timer 1
	orl TMOD, #0x20 ; Set timer 1 in 8-bit auto reload mode
	orl PCON, #80H ; Set SMOD to 1
	mov TH1, #low(TIMER_1_RELOAD)
	mov TL1, #low(TIMER_1_RELOAD)
	setb TR1 ; Enable timer 1
	mov SCON, #52H
    setb TI  ; FIX: prime TX so first putchar doesn't stall
	ret


; -----------------------------
; ADDED: UART TX helpers
; -----------------------------
putchar:
    jnb TI, $
    clr TI
    mov SBUF, a
    ret

; SendString:
SendString:
    clr a
    movc a, @a+dptr
    jz SendString_done
    lcall putchar
    inc dptr
    sjmp SendString
SendString_done:
    ret




;---------------------------------;
; PrintU32: prints unsigned 32-bit ;
; integer in x as decimal over UART;
; Uses div32 (math32.inc): quotient in x, remainder in y
;---------------------------------;


PrintU32:
    ; if x == 0 -> print '0'
    mov a, x+0
    orl a, x+1
    orl a, x+2
    orl a, x+3
    jnz PU32_go

    mov a, #'0'
    lcall putchar
    ret
    
    
playSingle_beep: 
mov beep_count, #1
ret

ten_beeps:
mov beep_count, #10
ret

five_beeps:
mov beep_count, #5
ret

PU32_go:
    mov R7, #0          ; count digits pushed

PU32_loop:
    Load_y(10)
    lcall div32         ; x = x/10, remainder in y (0..9)

    mov a, y+0
    add a, #'0'         ; remainder -> ASCII digit
    push acc
    inc R7

    mov a, x+0
    orl a, x+1
    orl a, x+2
    orl a, x+3
    jnz PU32_loop

PU32_pop:
    pop acc
    lcall putchar
    djnz R7, PU32_pop
    ret


send_temp_serial:
    ; x = t_hot (centi-degC)
    mov x+0, t_hot+0
    mov x+1, t_hot+1
    mov x+2, t_hot+2
    mov x+3, t_hot+3

    ; x = x / 100  -> integer degrees C
    Load_y(100)
    lcall div32          ; x now = integer °C (0..300-ish)
    mov temp, x+0

    ; --- print as exactly 3 digits: H T O ---
    ; R3:R4 = x (16-bit is enough here)
    mov R4, x+0
    mov R3, x+1

    ; hundreds in R2
    mov R2, #0

Hund_loop:
    ; if (R3:R4) < 100 stop
    mov a, R3
    jnz Hund_sub
    mov a, R4
    clr c
    subb a, #100
    jc  Hund_done

Hund_sub:
    ; (R3:R4) -= 100
    mov a, R4
    clr c
    subb a, #100
    mov R4, a
    mov a, R3
    subb a, #0
    mov R3, a
    inc R2
    sjmp Hund_loop

Hund_done:
    ; print hundreds
    mov a, R2
    add a, #'0'
    lcall putchar

    ; print tens and ones from remaining 0..99 in R4
    mov a, R4
    mov b, #10
    div ab              ; A=tens, B=ones

    add a, #'0'
    lcall putchar
    mov a, b
    add a, #'0'
    lcall putchar

    ; CRLF
    mov a, #0Dh
    lcall putchar
    mov a, #0Ah
    lcall putchar
    ret




Read_ADC:
	mov ADC_C, a
	mov R1, ADC_H
	mov R0, ADC_L
	ret

;---------------------------------
; Read_Ref
; Reads LM4040 reference on ADC channel 0
; Stores 16-bit ADC count in VAL_LM4040 (low,high)
;---------------------------------
Read_Ref:
    mov a, #00h            ; ADC channel 0 (AIN0)
    lcall Read_ADC
    mov VAL_LM4040+0, R0
    mov VAL_LM4040+1, R1
    ret


;---------------------------------
; Read_op_amp_mv
; Reads op-amp output on ADC channel 1 (you set #01h)
; Computes V_amp_mv in TRUE mV:
;   Vopamp_mV = ADC_opamp * 4096 / ADC_ref
; Stores result as 32-bit in V_amp_mv
;---------------------------------
Read_op_amp_mv:
    ; if reference reading is 0, avoid divide-by-zero
    mov A, VAL_LM4040+0
    orl A, VAL_LM4040+1
    jnz _ref_ok

    ; V_amp_mv = 0
    mov V_amp_mv+0, #00h
    mov V_amp_mv+1, #00h
    mov V_amp_mv+2, #00h
    mov V_amp_mv+3, #00h
    ret

_ref_ok:
    ; Read op-amp output ADC channel 1 (AIN1)
    mov a, #01h
    lcall Read_ADC

    ; x = ADC_opamp (16-bit)
    mov x+0, R0
    mov x+1, R1
    mov x+2, #00h
    mov x+3, #00h

    ; x = x * 4096  (mV)
    Load_y(2500)
    lcall mul32

    ; y = ADC_ref (16-bit)
    mov y+0, VAL_LM4040+0
    mov y+1, VAL_LM4040+1
    mov y+2, #00h
    mov y+3, #00h

    ; x = (ADC_opamp * 4096) / ADC_ref  => mV
    lcall div32

    ; store TRUE mV into V_amp_mv
    mov V_amp_mv+0, x+0
    mov V_amp_mv+1, x+1
    mov V_amp_mv+2, x+2
    mov V_amp_mv+3, x+3
    ret


;---------------------------------
; VoutmV_To_TempC
; Uses V_amp_mv (TRUE mV)
; Steps:
; 1) uV_opamp = mV * 1000
; 2) uV_tc    = uV_opamp / GAIN (300)
; 3) Temp_cC  = uV_tc * 100 / 41    (41 uV per 1°C)
; 4) add T_cold (centi-°C)
; Output: t_hot = total temp in centi-°C (°C*100)
;---------------------------------
VoutmV_To_TempC:
    ; x = V_amp_mv (mV)
    mov A, V_amp_mv+0
    mov x+0, A
    mov A, V_amp_mv+1
    mov x+1, A
    mov A, V_amp_mv+2
    mov x+2, A
    mov A, V_amp_mv+3
    mov x+3, A

    ; uV_opamp = mV * 1000
    Load_y(1000)
    lcall mul32

    ; uV_tc = uV_opamp / 300
    Load_y(300)
    lcall div32

    ; Temp_cC = uV_tc * 100 / 41
    Load_y(100)
    lcall mul32

    Load_y(41)
    lcall div32          ; x now = temp in centi-°C from thermocouple only

    ; add cold junction temp (centi-°C)
    mov A, T_cold+0
    mov y+0, A
    mov A, T_cold+1
    mov y+1, A
    mov A, T_cold+2
    mov y+2, A
    mov A, T_cold+3
    mov y+3, A
    
    
    

    lcall add32          ; x = x + y

    ; store into t_hot (centi-°C)
    mov A, x+0
    mov t_hot+0, A
    mov A, x+1
    mov t_hot+1, A
    mov A, x+2
    mov t_hot+2, A
    mov A, x+3
    mov t_hot+3, A
    ret 


send_temp_serial_simple:
    mov dptr, #TempLabel
    lcall SendString
    ; x = t_hot
    mov x+0, t_hot+0
    mov x+1, t_hot+1
    mov x+2, t_hot+2
    mov x+3, t_hot+3
    lcall PrintU32
    mov a, #0Dh
    lcall putchar
    mov a, #0Ah
    lcall putchar
    ret
    
HexTab: db '0123456789ABCDEF',0

PrintHexNibble:
    ; A = 0..15
    mov dptr, #HexTab
    movc a, @a+dptr
    lcall putchar
    ret

PrintHex8:
    ; A = byte
    push acc
    swap a
    anl a, #0Fh
    lcall PrintHexNibble
    pop acc
    anl a, #0Fh
    lcall PrintHexNibble
    ret

PrintHex16_R1R0:
    ; prints R1 then R0 as 4 hex digits
    mov a, R1
    lcall PrintHex8
    mov a, R0
    lcall PrintHex8
    ret

ADC0Label: db 'AIN0=0x',0
ADC1Label: db ' AIN1=0x',0

send_adc_debug:
    ; AIN0
    mov a, #00h
    lcall Read_ADC              ; R1:R0 valid?

    mov dptr, #ADC0Label
    lcall SendString
    lcall PrintHex16_R1R0

    ; AIN1
    mov a, #01h
    lcall Read_ADC

    mov dptr, #ADC1Label
    lcall SendString
    lcall PrintHex16_R1R0

    ; CRLF
    mov a, #0Dh
    lcall putchar
    mov a, #0Ah
    lcall putchar
    ret
    
VLabel: db ' Vop_mV=',0
    
PrintHex32_Vamp:
    ; prints V_amp_mv+3..+0 as 8 hex digits
    mov a, V_amp_mv+3
    lcall PrintHex8
    mov a, V_amp_mv+2
    lcall PrintHex8
    mov a, V_amp_mv+1
    lcall PrintHex8
    mov a, V_amp_mv+0
    lcall PrintHex8
    ret

send_v_debug_hex:
    mov dptr, #VLabel
    lcall SendString
    lcall PrintHex32_Vamp
    mov a, #0Dh
    lcall putchar
    mov a, #0Ah
    lcall putchar
    ret


    
end
