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
; ADDITIONS YOU ASKED FOR:
;   8) Total elapsed time (seconds) displayed on LCD in all states except 0,
;      maintained by Timer2 ISR, resets when returning to state 0.
;   9) Reset button (KEY0) forces state 0 and resets everything.
;
; NEW ADDITION (ACCELEROMETER TILT ABORT):
;   Uses the DE10-Lite onboard ADXL345 accelerometer. If board tilts too much
;   (|X| or |Y| exceeds threshold), aborts process by forcing state 6, turning
;   heater off, and sounding ten beeps.

$NOLIST
$MODMAX10
$LIST

CLK           EQU 33333333
TIMER0_RATE   EQU 4096
TIMER0_RELOAD EQU ((65536-(CLK/(12*TIMER0_RATE))))
TIMER2_RATE   EQU 1000
TIMER2_RELOAD EQU ((65536-(CLK/(12*TIMER2_RATE))))

SOUND_OUT     equ P1.5
UPDOWN        equ SWA.0
Play_beeps_Switch equ SWA.4
Start_Switch equ SWA.2
Abort_switch equ SWA.7

; RESET BUTTON (NEW)
RESET_BTN     equ KEY.0

SSR_PIN equ P3.7

; ==============================
; ADXL345 (DE10-Lite onboard) SPI pins
; ==============================
GSENSOR_SDI  BIT 0xfd ; MOSI
GSENSOR_SDO  BIT 0xfd ; MISO
GSENSOR_SCLK BIT 0xfe
GSENSOR_CS_n BIT 0xff

; Tilt threshold (16-bit). Tune this for demo.
; Start at 0x0600. If too sensitive -> 0x0800. If not sensitive -> 0x0400.
TILT_TH_HI  EQU 00h
TILT_TH_LO  EQU 0C0h

BAUD            EQU 57600
TIMER_1_RELOAD  EQU (256-((2*CLK)/(12*32*BAUD)))

org 0x0000
    ljmp main

org 0x0003
reti

org 0x000B
ljmp Timer0_ISR

org 0x0013
reti

org 0x001B
reti

org 0x0023
reti

org 0x002B
ljmp Timer2_ISR

dseg at 0x30
Count1ms:     ds 2
count_ms:     ds 2

BCD_counter:  ds 1
beep_count:   ds 1
beep_state:   ds 1
FSM1_state:   ds 1
temp_soak:    ds 1
Time_soak:    ds 1
Temp_refl:    ds 1
Time_refl:    ds 1
pwm_counter:  ds 1
pwm:          ds 1
temp:         ds 1
sec:          ds 1

;LCD FUNCTION
last_lcd_state: ds 1

; NEW: total elapsed time since leaving state0
elapsed_sec:  ds 2   ; 16-bit seconds, displayed as 4 digits (0000..9999)

x : ds 4
y : ds 4
bcd : ds 5

V_amp_mv: ds 4
T_cold: ds 4
t_hot : ds 4
VAL_LM4040: ds 2

param_sel:     ds 1
edit_value:    ds 1
edit_digits:   ds 1
prev_sel:      ds 1

; ==============================
; ADXL345 raw readings + tilt flag
; ==============================
ax_l: ds 1
ax_h: ds 1
ay_l: ds 1
ay_h: ds 1
az_l: ds 1
az_h: ds 1
tilt_fault: ds 1

bseg
half_seconds_flag: dbit 1
mf : dbit 1
Reached50_flag: dbit 1

cseg
ELCD_RS equ P1.7
ELCD_E  equ P1.1
ELCD_D4 equ P0.7
ELCD_D5 equ P0.5
ELCD_D6 equ P0.3
ELCD_D7 equ P0.1

InitialString: db '\r\nHello, World!\r\n', 0
$NOLIST
$include(LCD_4bit_DE10Lite_no_RW.inc)
$include(math32.inc)
$LIST

Initial_Message:  db 'TempC= xx ', 0

State0_Line1: db 'sC  sT  rC  rT',0
State0_Line2: db '',0

;LCD FUNCTION
State1_Line1: db 'S1 PREHEAT  ', 0
State2_Line1: db 'S2 SOAK     ', 0
State3_Line1: db 'S3 REFLOW   ', 0
State4_Line1: db 'S4 HOLD     ', 0
State5_Line1: db 'S5 COOL     ', 0
State6_Line1: db 'S6 ERROR    ', 0

Timer0_Init:
mov a, TMOD
anl a, #0xf0
orl a, #0x01
mov TMOD, a
mov TH0, #high(TIMER0_RELOAD)
mov TL0, #low(TIMER0_RELOAD)
setb ET0
clr TR0
ret

Timer0_ISR:
mov TH0, #high(TIMER0_RELOAD)
mov TL0, #low(TIMER0_RELOAD)
cpl SOUND_OUT
reti

Timer2_Init:
mov T2CON, #0
mov TH2, #high(TIMER2_RELOAD)
mov TL2, #low(TIMER2_RELOAD)
mov RCAP2H, #high(TIMER2_RELOAD)
mov RCAP2L, #low(TIMER2_RELOAD)

clr a
mov Count1ms+0, a
mov Count1ms+1, a
mov count_ms+0, a
mov count_ms+1, a

; NEW
mov elapsed_sec+0, a
mov elapsed_sec+1, a

    setb ET2
    setb TR2
ret

; ==========================================================
; Timer2 ISR: PWM + ms tick + sec tick + total elapsed time
; ==========================================================
Timer2_ISR:
    clr TF2
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
    clr SSR_PIN
    sjmp pwm_done

turn_ssr_on:
    setb SSR_PIN

pwm_done:
    ; --- TIME KEEPING (ms counters) ---
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

    ; ---- 1 second tick ----
    mov a, count_ms+0
    cjne a, #low(1000), Check_500ms
    mov a, count_ms+1
    cjne a, #high(1000), Check_500ms

    ; 1 second passed: update sec (your per-state timer)
    inc sec
    clr a
    mov count_ms+0, a
    mov count_ms+1, a

    ; NEW: total elapsed seconds since leaving state0
    mov a, FSM1_state
    jz Elapsed_Reset_In_ISR

    ; if elapsed_sec = 999, saturate
    mov a, elapsed_sec+1
    cjne a, #high(999), Elapsed_Not_MaxHi
    mov a, elapsed_sec+0
    cjne a, #low(999), Elapsed_Not_MaxHi
    sjmp Check_500ms

Elapsed_Not_MaxHi:
    inc elapsed_sec+0
    mov a, elapsed_sec+0
    jnz Check_500ms
    inc elapsed_sec+1
    sjmp Check_500ms

Elapsed_Reset_In_ISR:
    clr a
    mov elapsed_sec+0, a
    mov elapsed_sec+1, a
    mov sec, a

Check_500ms:
    mov a, Count1ms+0
    cjne a, #low(500), beep_logic
    mov a, Count1ms+1
    cjne a, #high(500), beep_logic

    clr a
    mov Count1ms+0, a
    mov Count1ms+1, a
    setb half_seconds_flag
    cpl LEDRA.0

    ; --- BEEP LOGIC ---
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

T_7seg:
    DB 0xC0, 0xF9, 0xA4, 0xB0, 0x99
    DB 0x92, 0x82, 0xF8, 0x80, 0x90
    DB 0x88, 0x83, 0xC6, 0xA1, 0x86, 0x8E

; ==========================================================
; NEW: Force reset to state0 and clear everything
; ==========================================================
Force_Reset_To_State0:
    push acc

    mov pwm, #0
    clr SSR_PIN

    mov FSM1_state, #0

    clr a
    mov sec, a
    mov elapsed_sec+0, a
    mov elapsed_sec+1, a

    mov beep_count, a
    clr TR0
    clr SOUND_OUT

    clr Reached50_flag

    pop acc
    ret

; ==========================================================
; NEW: Show elapsed time on LCD (row1 col13..16) if state != 0
; Displays elapsed seconds as 4 digits, saturates at 9999.
; ==========================================================
Display_Elapsed_LCD:
    push acc
    push b
    push psw
    push dpl
    push dph
   
   
    anl PSW, #0E7H ;
   
    ; save the R registers
   
    push 00h
    push 01h
    push 03h
    push 04h
    push 07h

    ; Only show if not state 0
    mov a, FSM1_state
    jz DEL_Clear

    ; Copy elapsed_sec to R3:R4 (16-bit)
    mov R4, elapsed_sec+0
    mov R3, elapsed_sec+1

    ; Cap at 9999 for display safety
    ; if R3:R4 > 9999 then force 9999
    mov a, R3
    clr c
    subb a, #high(999)
    jc DEL_Print
    jnz DEL_Force999
    mov a, R4
    clr c
    subb a, #low(999)
    jnc DEL_Force999
    sjmp DEL_Print

DEL_Force999:
    mov R3, #high(999)
    mov R4, #low(999)

DEL_Print:
    ; thousands, hundreds, tens, ones using repeated subtraction
    mov R1, #0    ; thousands
;DEL_Thou_L:
    ; if < 1000 stop
    ;mov a, R3
    ;jnz DEL_Thou_Sub
    ;mov a, R4
    ;clr c
    ;subb a, #low(1000)
    ;jc DEL_Thou_D
;DEL_Thou_Sub:
    ;; (R3:R4) -= 1000
    ;mov a, R4
    ;clr c
    ;subb a, #low(1000)
    ;mov R4, a
    ;mov a, R3
    ;subb a, #high(1000)
    ;mov R3, a
    ;inc R2
    ;sjmp DEL_Thou_L
;DEL_Thou_D:

    ;mov R1, #0    ; hundreds
DEL_Hund_L:
    ; if < 100 stop
    mov a, R3
    jnz DEL_Hund_Sub
    mov a, R4
    clr c
    subb a, #100
    jc DEL_Hund_D
DEL_Hund_Sub:
    mov a, R4
    clr c
    subb a, #100
    mov R4, a
    mov a, R3
    subb a, #0
    mov R3, a
    inc R1
    sjmp DEL_Hund_L
DEL_Hund_D:

    ; tens and ones from remaining (0..99) in R4
    mov a, R4
    mov b, #10
    div ab        ; A=tens, B=ones
    mov R0, A     ; tens
    mov R7, B     ; ones

    ; Print at row1 col14..16
    Set_Cursor(1, 14)
    mov a, R1
    add a, #'0'
    lcall ?WriteData
    mov a, R0
    add a, #'0'
    lcall ?WriteData
    mov a, R7
    add a, #'0'
    lcall ?WriteData
    sjmp DEL_Done

DEL_Clear:
    ; In state0, clear those 4 slots
    Set_Cursor(1, 14)
    mov a, #' '
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData

DEL_Done:


pop 07h
pop 04h
pop 03h
pop 01h
pop 00h


pop dph
pop dpl
    pop psw
    pop b
    pop acc
    ret
   

;LCD FUNCTION
Clear_LCD_OnStateChange:

push acc
push psw
push dpl
push dph
push 0

mov a, FSM1_state
cjne a, last_lcd_state, CLS_clear
sjmp CLS_done

CLS_clear:

mov last_lcd_state, a

Set_Cursor(1,1)
mov R0, #13

CLS_row1:

mov a, #' '
lcall ?WriteData
djnz R0, CLS_row1

Set_Cursor(2,1)
mov R0, #16

CLS_row2:

mov a, #' '
lcall ?WriteData
djnz R0, CLS_row2

CLS_done:

pop 0
pop dph
pop dpl
pop psw
pop acc
ret

;LCD FUNCTION

Draw_State_Header_Row1:

push acc
push dpl
push dph


mov a, FSM1_state
jnz DSH_s1 ; if in state 0 don't print the state header
ljmp DSH_done

DSH_s1:
Set_Cursor(1,1)

cjne a, #1, DSH_s2
Send_Constant_String(#State1_Line1)
sjmp DSH_done

DSH_s2:

    cjne a, #2, DSH_s3
    Send_Constant_String(#State2_Line1)
    sjmp DSH_done

DSH_s3:

    cjne a, #3, DSH_s4
    Send_Constant_String(#State3_Line1)
    sjmp DSH_done

DSH_s4:

    cjne a, #4, DSH_s5
    Send_Constant_String(#State4_Line1)
    sjmp DSH_done

DSH_s5:

    cjne a, #5, DSH_s6
    Send_Constant_String(#State5_Line1)
    sjmp DSH_done

DSH_s6:

    Send_Constant_String(#State6_Line1)

DSH_done:
    pop dph
    pop dpl
    pop acc
   
   
   
;Target time or temp depending on state on the second row

Display_Target_Row2:


push acc
push b
push psw
push dpl
push dph


mov a, FSM1_state

jnz Target_State1
ljmp Target_Done


Target_State1:

Set_Cursor(2,1)


;State 1
cjne a, #1, Target_State2

mov a, #'T'
lcall ?WriteData
mov a, #'='
lcall ?WriteData
    mov a, #'5'
    lcall ?WriteData
    mov a, #'0'
    lcall ?WriteData
    mov a, #'C'
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #'t'
lcall ?WriteData
    mov a, #'='
    lcall ?WriteData
    mov a, #'6'
    lcall ?WriteData
    mov a, #'0'
    lcall ?WriteData
    ljmp Target_Done
   
   
Target_State2:


;State 2
cjne a, #2, Target_State3

mov a, #'T'
lcall ?WriteData
    mov a, #'='
    lcall ?WriteData
    mov a, temp_soak
    lcall LCD_Print3Dec
    mov a, #' '
    lcall ?WriteData
    mov a, #'t'
lcall ?WriteData
    mov a, #'='
    lcall ?WriteData
    mov a, time_soak
    lcall LCD_Print3Dec
    ljmp Target_Done
   
Target_State3:

cjne a, #3, Target_State4

mov a, #'T'
lcall ?WriteData
    mov a, #'='
    lcall ?WriteData
    mov a, temp_refl
    lcall LCD_Print3Dec
    sjmp Target_Done

Target_State4:

cjne a, #4, Target_State5

mov a, #'t'
lcall ?WriteData
    mov a, #'='
    lcall ?WriteData
    mov a, time_refl
    lcall LCD_Print3Dec
    sjmp Target_Done
   
   
Target_State5:

cjne a, #5, Target_State6


mov a, #'T'
lcall ?WriteData
    mov a, #'='
    lcall ?WriteData
    mov a, #'0'
    lcall ?WriteData
    mov a, #'6'
    lcall ?WriteData
    mov a, #'0'
    lcall ?WriteData
    mov a, #'C'
    lcall ?WriteData
    sjmp Target_Done

Target_State6:

mov a, #'C'
    lcall ?WriteData
    mov a, #'R'
    lcall ?WriteData
    mov a, #'I'
    lcall ?WriteData
    mov a, #'T'
    lcall ?WriteData
    mov a, #'I'
    lcall ?WriteData
    mov a, #'C'
    lcall ?WriteData
    mov a, #'A'
    lcall ?WriteData
mov a, #'L'
    lcall ?WriteData
   
Target_Done:

pop dph
pop dpl
    pop psw
    pop b
    pop acc
    ret

; -----------------------------------
; FSM1
; -----------------------------------
FSM1:
mov a, FSM1_state

FSM_state0:
cjne a, #0, FSM1_state1
mov pwm, #0

mov a, edit_digits
jnz S0_sel_same

lcall ReadParamSel_SW01

mov a, param_sel
cjne a, prev_sel, S0_sel_changed
sjmp S0_sel_same

S0_sel_changed:
mov prev_sel, param_sel
mov edit_value, #0
mov edit_digits, #0

S0_sel_same:

    lcall Get3Digits
    jnc S0_not_ready

    mov a, edit_value
    lcall ApplyEditValue_ToSelectedParam

    mov edit_value, #0
    mov edit_digits, #0

S0_not_ready:
  lcall State0_DrawLCD

jb Start_Switch, FSM1_state0_done
mov sec, #0
clr Reached50_flag
mov FSM1_state, #1
lcall playSingle_beep

FSM1_state0_done:
ljmp FSM2

; state 1 ramping to soak
FSM1_state1:
cjne a, #1, FSM1_state2
mov pwm, #100
;abort button check
jb Abort_switch , error_found_jump

    mov a, temp
    clr c
    subb a, #50
    jc  temp_below_50
    setb Reached50_flag

temp_below_50:
    mov a, sec
    clr c
    subb a, #60
    jc  continue_preheat
    jb  Reached50_flag, continue_preheat

    mov pwm, #0
    mov sec, #0
    mov FSM1_state, #6
    lcall ten_beeps
    ljmp FSM2

continue_preheat:
    mov a, temp_soak
    clr c
    subb a, temp
    jnc FSM1_state1_done
    mov sec, #0
    mov FSM1_state, #2
    lcall playSingle_beep

FSM1_state1_done:
ljmp FSM2

error_found_jump:
sjmp error_found

FSM1_state2:
cjne a, #2, FSM1_state3
jb Abort_switch, error_found
mov pwm, #20
mov a, time_soak
clr c
subb a, sec
jnc FSM1_state2_done
mov sec, #0
mov FSM1_state, #3
lcall playSingle_beep

FSM1_state2_done:
ljmp FSM2

FSM1_state3:
cjne a, #3, FSM1_state4
jb Abort_switch, error_found
mov pwm, #100
mov a, temp_refl
clr c
subb a, temp
jnc FSM1_state3_done
mov sec, #0
mov FSM1_state, #4
lcall playSingle_beep

FSM1_state3_done:
ljmp FSM2

FSM1_state4:
cjne a, #4, FSM1_state5
jb Abort_switch, error_found
mov pwm, #20
mov a, time_refl
clr c
subb a, sec
jnc FSM1_state4_done
mov sec, #0
mov FSM1_state, #5
lcall playSingle_beep

FSM1_state4_done:
ljmp FSM2

FSM1_state5:
cjne a, #5, FSM1_state6
mov pwm, #0
mov a, temp
clr c
subb a, #60
jnc FSM_state5_done
lcall five_beeps
mov FSM1_state, #0

FSM_state5_done:
ljmp FSM2

error_found:
sjmp trigger_error

trigger_error:
mov FSM1_state, #5
mov pwm , #0
lcall ten_beeps
ljmp FSM2

; error check
FSM1_state6:
    cjne a, #6, not_error
    sjmp is_error

not_error:
    ljmp FSM_state0

is_error:
    mov pwm, #0
    jb Start_Switch, FSM_state6_done
    ljmp FSM2

FSM_state6_done:
    mov FSM1_state, #0
    ljmp FSM2

;---------------------------------;
; Main program
;---------------------------------;
main:
    mov SP, #0x70
    mov FSM1_state, #0
   
    ;LCD FUNCTION
    mov last_lcd_state, #0
    ;setb ES


    lcall Timer0_Init
    lcall Timer2_Init
    lcall Initialize_Serial_Port

    mov P0MOD, #10101010b
    mov P1MOD, #10100010b
    mov P2MOD, #0xff
    mov P3MOD, #0xff

    ; ==============================
    ; Init ADXL345 (onboard accelerometer)
    ; ==============================
    lcall ADXL345_Configure
    mov tilt_fault, #0

    mov LEDRA, #0
    mov LEDRB, #0

    setb EA
    lcall ELCD_4BIT

Set_Cursor(1, 1)
    Send_Constant_String(#Initial_Message)
    setb half_seconds_flag
mov BCD_counter, #0x00

    mov T_cold+0, #098h
    mov T_cold+1, #008h
    mov T_cold+2, #000h
    mov T_cold+3, #000h
mov ADC_C, #080h
Wait_Milli_Seconds(#50)

    mov temp_soak,  #150
    mov time_soak,  #60
    mov temp_refl,  #220
    mov time_refl,  #45

    lcall Configure_Keypad_Pins

    lcall ReadParamSel_SW01
    mov  prev_sel, param_sel
    mov  edit_value, #0
    mov  edit_digits, #0

    ; NEW
    clr a
    mov elapsed_sec+0, a
    mov elapsed_sec+1, a

FSM2:
; ==========================================================
; RESET BUTTON (KEY0) to force state0 and reset everything
; ==========================================================
    jb RESET_BTN, FSM2_NoReset
    Wait_Milli_Seconds(#50)
    jb RESET_BTN, FSM2_NoReset
    jnb RESET_BTN, $      ; wait release
    lcall Force_Reset_To_State0
FSM2_NoReset:

skip_beep:

; KEY1 handling (your original counter reset)
jb KEY.1, loop_a
Wait_Milli_Seconds(#50)
jb KEY.1, loop_a
jnb KEY.1, $
clr TR2
clr a
mov Count1ms+0, a
mov Count1ms+1, a
mov BCD_counter, a
setb TR2
ljmp loop_b

loop_a:
jnb half_seconds_flag, loop_b


Set_Cursor(1,7)
    lcall Display_TempC_7seg
    ;lcall send_temp_serial
    lcall send_all_serial_3digits
    lcall PrintStateSerial

    ; ==============================
    ; Tilt abort check (runs at 500ms rate)
    ; ==============================
    lcall Check_Tilt_Abort

loop_b:
    clr half_seconds_flag
    lcall Read_Ref
    lcall Read_op_amp_mv
    lcall VoutmV_To_TempC

    ; NEW: show total elapsed time (seconds) on LCD in states 1..6
    lcall Clear_LCD_OnStateChange
    lcall Draw_State_Header_Row1
    lcall Display_Elapsed_LCD
    lcall Display_StateTimer_LCD
    lcall Serial_Command_Service

    ljmp FSM1

; ===== SUBROUTINES BELOW =====


Display_StateTimer_LCD:
    push acc
    push b
    push psw
    push dpl
    push dph

    anl PSW, #0E7h    

    ; If state  blank
    mov a, FSM1_state
    jz DST_Clear

    ; Clamp sec to 999 just in case
    mov a, sec
    clr c
    subb a, #100      

    ; Convert sec
    mov a, sec
    mov b, #100
    div ab             ; a = hundreds, b = remainder
    mov R2, a          ; hundreds
    mov a, b
    mov b, #10
    div ab             ; a = tens, b = ones
    mov R1, a          ; tens
    mov R0, b          ; ones

    ; Print at row2 col14..16
    Set_Cursor(2, 14)
    mov a, R2
    add a, #'0'
    lcall ?WriteData
    mov a, R1
    add a, #'0'
    lcall ?WriteData
    mov a, R0
    add a, #'0'
    lcall ?WriteData
    sjmp DST_Done

DST_Clear:
    Set_Cursor(2, 14)
    mov a, #' '
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData
    mov a, #' '
    lcall ?WriteData

DST_Done:
    pop dph
    pop dpl
    pop psw
    pop b
    pop acc
    ret



Display_TempC_7Seg:
    push acc
    push b
    push dpl
    push dph

    mov x+0, t_hot+0
    mov x+1, t_hot+1
    mov x+2, t_hot+2
    mov x+3, t_hot+3

    Load_y(100)
    lcall div32

    mov R4, x+0
    mov R3, x+1

    mov R2, #0

DT_Hund_Loop:
    mov a, R3
    jnz DT_Hund_Sub
    mov a, R4
    clr c
    subb a, #100
    jc  DT_Hund_Done

DT_Hund_Sub:
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
    mov a, R4
    mov b, #10
    div ab
    mov R1, A
    mov R0, B

    mov dptr, #T_7seg

    mov a, R0
    movc a, @a+dptr
    mov HEX0, a

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

Initialize_Serial_Port:
clr TR1
anl TMOD, #0x0f
orl TMOD, #0x20
orl PCON, #80H
mov TH1, #low(TIMER_1_RELOAD)
mov TL1, #low(TIMER_1_RELOAD)
setb TR1
mov SCON, #52H
    setb TI
ret

putchar:
    jnb TI, $
    clr TI
    mov SBUF, a
    ret

SendString:
    clr a
    movc a, @a+dptr
    jz SendString_done
    lcall putchar
    inc dptr
    sjmp SendString
SendString_done:
    ret

PrintU32:
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
clr a
mov Count1ms+0, a
mov Count1ms+1, a
ret

ten_beeps:
mov beep_count, #10
clr a
mov Count1ms+0, a
mov Count1ms+1, a
ret

five_beeps:
mov beep_count, #5
clr a
mov Count1ms+0, a
mov Count1ms+1, a
ret

PU32_go:
    mov R7, #0

PU32_loop:
    Load_y(10)
    lcall div32

    mov a, y+0
    add a, #'0'
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
    mov x+0, t_hot+0
    mov x+1, t_hot+1
    mov x+2, t_hot+2
    mov x+3, t_hot+3

    Load_y(100)
    lcall div32
    mov temp, x+0

    mov R4, x+0
    mov R3, x+1

    mov R2, #0

Hund_loop:
    mov a, R3
    jnz Hund_sub
    mov a, R4
    clr c
    subb a, #100
    jc  Hund_done

Hund_sub:
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
    mov a, R2
    add a, #'0'
    lcall putchar

    mov a, R4
    mov b, #10
    div ab

    add a, #'0'
    lcall putchar
    mov a, b
    add a, #'0'
    lcall putchar

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

Read_Ref:
    mov a, #00h
    lcall Read_ADC
    lcall Read_ADC
    mov VAL_LM4040+0, R0
    mov VAL_LM4040+1, R1
    ret

Read_op_amp_mv:
    mov A, VAL_LM4040+0
    orl A, VAL_LM4040+1
    jnz _ref_ok

    mov V_amp_mv+0, #00h
    mov V_amp_mv+1, #00h
    mov V_amp_mv+2, #00h
    mov V_amp_mv+3, #00h
    ret

_ref_ok:
    mov a, #01h
    lcall Read_ADC
    lcall Read_ADC

    mov x+0, R0
    mov x+1, R1
    mov x+2, #00h
    mov x+3, #00h

    Load_y(4096)
    lcall mul32

    mov y+0, VAL_LM4040+0
    mov y+1, VAL_LM4040+1
    mov y+2, #00h
    mov y+3, #00h

    lcall div32

    mov V_amp_mv+0, x+0
    mov V_amp_mv+1, x+1
    mov V_amp_mv+2, x+2
    mov V_amp_mv+3, x+3
    ret

VoutmV_To_TempC:

  clr a
  mov t_hot+0, a
  mov t_hot+1, a
  mov t_hot+2, a
  mov t_hot+3, a
  mov R3, #10

 loop_temp:

  lcall Read_op_amp_mv

  mov x+0, t_hot+0
  mov x+1, t_hot+1
  mov x+2, t_hot+2
  mov x+3, t_hot+3

    mov A, V_amp_mv+0
    mov y+0, A
    mov A, V_amp_mv+1
    mov y+1, A
    mov A, V_amp_mv+2
    mov y+2, A
    mov A, V_amp_mv+3
    mov y+3, A

    lcall add32

    mov t_hot+0, x+0
    mov t_hot+1, x+1
    mov t_hot+2, x+2
    mov t_hot+3, x+3

    djnz R3, loop_temp

average_val:

mov x+0, t_hot+0
mov x+1, t_hot+1
mov x+2, t_hot+2
mov x+3, t_hot+3

load_y(10)
lcall div32

    Load_y(1000)
    lcall mul32

    Load_y(306)
    lcall div32

    Load_y(100)
    lcall mul32

    Load_y(41)
    lcall div32

    mov A, T_cold+0
    mov y+0, A
    mov A, T_cold+1
    mov y+1, A
    mov A, T_cold+2
    mov y+2, A
    mov A, T_cold+3
    mov y+3, A

    lcall add32

    mov A, x+0
    mov t_hot+0, A
    mov A, x+1
    mov t_hot+1, A
    mov A, x+2
    mov t_hot+2, A
    mov A, x+3
    mov t_hot+3, A
    ret

StateLabel: db 'STATE=',0
PrintStateSerial:
    push acc
    push dpl
    push dph

    mov dptr, #StateLabel
    lcall SendString

    mov a, FSM1_state
    add a, #'0'
    lcall putchar

    mov a, #0Dh
    lcall putchar
    mov a, #0Ah
    lcall putchar

    pop dph
    pop dpl
    pop acc
    ret

LCD_Print3Dec:
    push acc
    push b
    push psw

    mov b, #100
    div ab
    add a, #'0'
    lcall ?WriteData

    mov a, b
    mov b, #10
    div ab
    add a, #'0'
    lcall ?WriteData

    mov a, b
    add a, #'0'
    lcall ?WriteData

    pop psw
    pop b
    pop acc
    ret

; ---- keypad code unchanged below ----

myLUT:
    DB 0xC0, 0xF9, 0xA4, 0xB0, 0x99        ; 0 TO 4
    DB 0x92, 0x82, 0xF8, 0x80, 0x90        ; 4 TO 9
    DB 0x88, 0x83, 0xC6, 0xA1, 0x86, 0x8E  ; A to F

showBCD MAC
; Display LSD
    mov A, %0
    anl a, #0fh
    movc A, @A+dptr
    mov %1, A
; Display MSD
    mov A, %0
    swap a
    anl a, #0fh
    movc A, @A+dptr
    mov %2, A
ENDMAC

MYRLC MAC
mov a, %0
rlc a
mov %0, a
ENDMAC

MYRRC MAC
mov a, %0
rrc a
mov %0, a
ENDMAC

Wait25ms:
;33.33MHz, 1 clk per cycle: 0.03us
mov R0, #15
L33:
mov R1, #74
L22:
mov R2, #250
L11:
djnz R2, L11 ;3*250*0.03us=22.5us
    djnz R1, L22 ;74*22.5us=1.665ms
    djnz R0, L33 ;1.665ms*15=25ms
    ret

CHECK_COLUMN MAC
jb %0, CHECK_COL_%M
mov R7, %1
jnb %0, $ ; wait for key release
setb c
ret
CHECK_COL_%M:
ENDMAC

Configure_Keypad_Pins:
; Configure the row pins as output and the column pins as inputs
orl P1MOD, #0b_01010100 ; P1.6, P1.4, P1.2 output
orl P2MOD, #0b_00000001 ; P2.0 output
anl P2MOD, #0b_10101011 ; P2.6, P2.4, P2.2 input
anl P3MOD, #0b_11111110 ; P3.0 input
ret

; These are the pins used for the keypad in this program:
ROW1 EQU P1.2
ROW2 EQU P1.4
ROW3 EQU P1.6
ROw4 EQU P2.0
COL1 EQU P2.2
COL2 EQU P2.4
COL3 EQU P2.6
COL4 EQU P3.0

Keypad:
$MESSAGE TIP: KEY1 is the erase key
jb KEY.1, keypad_L0
lcall Wait25ms ; debounce
jb KEY.1, keypad_L0
jnb KEY.1, $ ; The key was pressed, wait for release
clr c
ret

keypad_L0:
clr ROW1
clr ROW2
clr ROW3
clr ROW4
mov c, COL1
anl c, COL2
anl c, COL3
anl c, COL4
jnc Keypad_Debounce
clr c
ret

Keypad_Debounce:
lcall Wait25ms ; debounce
mov c, COL1
anl c, COL2
anl c, COL3
anl c, COL4
jnc Keypad_Key_Code
clr c
ret

Keypad_Key_Code:
setb ROW1
setb ROW2
setb ROW3
setb ROW4

keypad_default:
clr ROW1
CHECK_COLUMN(COL1, #01H)
CHECK_COLUMN(COL2, #02H)
CHECK_COLUMN(COL3, #03H)
CHECK_COLUMN(COL4, #0AH)
setb ROW1

clr ROW2
CHECK_COLUMN(COL1, #04H)
CHECK_COLUMN(COL2, #05H)
CHECK_COLUMN(COL3, #06H)
CHECK_COLUMN(COL4, #0BH)
setb ROW2

clr ROW3
CHECK_COLUMN(COL1, #07H)
CHECK_COLUMN(COL2, #08H)
CHECK_COLUMN(COL3, #09H)
CHECK_COLUMN(COL4, #0CH)
setb ROW3

clr ROW4
CHECK_COLUMN(COL1, #0EH)
CHECK_COLUMN(COL2, #00H)
CHECK_COLUMN(COL3, #0FH)
CHECK_COLUMN(COL4, #0DH)
setb ROW4

clr c
ret

keypad_90deg:
clr ROW1
CHECK_COLUMN(COL1, #0AH)
CHECK_COLUMN(COL2, #0BH)
CHECK_COLUMN(COL3, #0CH)
CHECK_COLUMN(COL4, #0DH)
setb ROW1

clr ROW2
CHECK_COLUMN(COL1, #03H)
CHECK_COLUMN(COL2, #06H)
CHECK_COLUMN(COL3, #09H)
CHECK_COLUMN(COL4, #0FH)
setb ROW2

clr ROW3
CHECK_COLUMN(COL1, #02H)
CHECK_COLUMN(COL2, #05H)
CHECK_COLUMN(COL3, #08H)
CHECK_COLUMN(COL4, #00H)
setb ROW3

clr ROW4
CHECK_COLUMN(COL1, #01H)
CHECK_COLUMN(COL2, #04H)
CHECK_COLUMN(COL3, #07H)
CHECK_COLUMN(COL4, #0EH)
setb ROW4

clr c
ret

Get3Digits:
    clr c
    push acc
    push b
    push psw

    lcall Keypad
    jnc G3_no_key

    mov a, R7
    cjne a, #0DH, G3_check_digit

    mov a, edit_digits
    jz G3_exit

    pop psw
    setb c
    pop b
    pop acc
    ret

G3_check_digit:
    mov a, R7
    clr c
    subb a, #0Ah
    jnc G3_exit

    mov a, edit_digits
    cjne a, #3, G3_build
    sjmp G3_exit

G3_build:
    mov a, edit_value
    add a, edit_value
    mov b, a
    mov a, edit_value
    rl a
    rl a
    rl a
    add a, b
    add a, R7

    mov edit_value, a
    inc edit_digits

    mov a, edit_digits
    cjne a, #3, G3_exit

    pop psw
    setb c
    pop b
    pop acc
    ret

G3_no_key:
    pop psw
    clr c
    pop b
    pop acc
    ret

G3_exit:
    pop psw
    clr c
    pop b
    pop acc
    ret

ReadParamSel_SW01:
    push acc
    clr a
    jb  SWA.0, RPS_bit0_1
    sjmp RPS_bit0_done
RPS_bit0_1:
    orl a, #01h
RPS_bit0_done:
    jb  SWA.1, RPS_bit1_1
    sjmp RPS_bit1_done
RPS_bit1_1:
    orl a, #02h
RPS_bit1_done:
    mov param_sel, a
    pop acc
    ret

ApplyEditValue_ToSelectedParam:
    push acc
    mov a, param_sel
    cjne a, #0, A1
    mov Temp_refl, edit_value
    sjmp ADone
A1: cjne a, #1, A2
    mov Time_refl, edit_value
    sjmp ADone
A2: cjne a, #2, A3
    mov temp_soak, edit_value
    sjmp ADone
A3:
    mov Time_soak, edit_value
ADone:
    pop acc
    ret

State0_DrawLCD:
    push acc
    push dpl
    push dph
    Set_Cursor(1,1)
    Send_Constant_String(#State0_Line1)
    Set_Cursor(2,1)
    Send_Constant_String(#State0_Line2)
    Set_Cursor(2,1)
    mov a, Temp_refl
    lcall LCD_Print3Dec
    Set_Cursor(2,5)
    mov a, Time_refl
    lcall LCD_Print3Dec
    Set_Cursor(2,9)
    mov a, temp_soak
    lcall LCD_Print3Dec
    Set_Cursor(2,13)
    mov a, Time_soak
    lcall LCD_Print3Dec
    pop dph
    pop dpl
    pop acc
    ret

KeyLED_LUT:
    DB 01h,00h
    DB 02h,00h
    DB 04h,00h
    DB 08h,00h
    DB 10h,00h
    DB 20h,00h
    DB 40h,00h
    DB 80h,00h
    DB 00h,01h
    DB 00h,02h
    DB 00h,04h
    DB 00h,08h
    DB 00h,10h
    DB 00h,20h
    DB 00h,40h
    DB 00h,80h

Keypad_Test_LEDs:
    push acc
    push dpl
    push dph

    lcall Keypad
    jnc KTL_no_key

    mov a, R7
    clr c
    subb a, #10h
    jnc KTL_done

    mov dptr, #KeyLED_LUT
    mov a, R7
    rl a
    movc a, @a+dptr
    mov LEDRA, a
    mov a, R7
    rl a
    inc a
    movc a, @a+dptr
    mov LEDRB, a
    sjmp KTL_done

KTL_no_key:

KTL_done:
    pop dph
    pop dpl
    pop acc
    ret

; ==========================================================
; ADXL345 SPI + Tilt Abort Feature
; ==========================================================

SPI_ByteRW:
    mov   R6, #8
    mov   R7, #0

SPI_Loop:
    mov   C, ACC.7
    mov   GSENSOR_SDI, C

    clr   GSENSOR_SCLK
    rl    A

    setb  GSENSOR_SCLK
    mov   C, GSENSOR_SDO
    push  acc
    mov   a, R7
    rlc   a
    mov   R7, a
    pop   acc

    djnz  R6, SPI_Loop
    mov   a, R7
    ret

ADXL345_WriteReg:
    setb  GSENSOR_SCLK
    clr   GSENSOR_CS_n
    mov   A, R0
    anl   A, #3Fh
    lcall SPI_ByteRW
    mov   A, R1
    lcall SPI_ByteRW
    setb  GSENSOR_CS_n
    ret

ADXL345_ReadReg:
    setb  GSENSOR_SCLK
    clr   GSENSOR_CS_n
    orl   A, #80h
    lcall SPI_ByteRW
    mov   A, #00h
    lcall SPI_ByteRW
    setb  GSENSOR_CS_n
    ret

ADXL345_ReadXYZ:
    setb  GSENSOR_SCLK
    clr   GSENSOR_CS_n

    mov   A, #0F2h
    lcall SPI_ByteRW

    mov   A, #00h
    lcall SPI_ByteRW
    mov ax_l, A

    mov   A, #00h
    lcall SPI_ByteRW
    mov ax_h, A

    mov   A, #00h
    lcall SPI_ByteRW
    mov ay_l, A

    mov   A, #00h
    lcall SPI_ByteRW
    mov ay_h, A

    mov   A, #00h
    lcall SPI_ByteRW
    mov az_l, A

    mov   A, #00h
    lcall SPI_ByteRW
    mov az_h, A

    setb  GSENSOR_CS_n
    ret

ADXL345_Configure:
    mov R0, #31h
    mov R1, #08h
    lcall ADXL345_WriteReg

    mov R0, #2Dh
    mov R1, #08h
    lcall ADXL345_WriteReg
    ret

Abs16_R3R2:
    mov a, R3
    jb  acc.7, abs_neg
    ret
abs_neg:
    mov a, R2
    cpl a
    mov R2, a
    mov a, R3
    cpl a
    mov R3, a
    inc R2
    mov a, R2
    jnz abs_done
    inc R3
abs_done:
    ret

Check_Tilt_Abort:
    push acc
    push psw
    ; force bank0 so we can safely push/pop R2,R3,R6,R7 by address
    anl PSW, #0E7h

    push b
    push dpl
    push dph
    push 02h      ; R2 (bank0)
    push 03h      ; R3 (bank0)
    push 06h      ; R6 (bank0)
    push 07h      ; R7 (bank0)

    mov a, FSM1_state
    jz  CTA_done

    lcall ADXL345_ReadXYZ

    ; abs(X)
    mov R2, ax_l
    mov R3, ax_h
    lcall Abs16_R3R2

    mov a, R3
    clr c
    subb a, #TILT_TH_HI
    jc  CTA_checkY
    jnz CTA_abort
    mov a, R2
    clr c
    subb a, #TILT_TH_LO
    jnc CTA_abort

CTA_checkY:
    ; abs(Y)
    mov R2, ay_l
    mov R3, ay_h
    lcall Abs16_R3R2

    mov a, R3
    clr c
    subb a, #TILT_TH_HI
    jc  CTA_done
    jnz CTA_abort
    mov a, R2
    clr c
    subb a, #TILT_TH_LO
    jnc CTA_abort
    sjmp CTA_done

CTA_abort:
    mov pwm, #0
    clr SSR_PIN
    mov sec, #0
    mov FSM1_state, #6
    mov tilt_fault, #1
    lcall ten_beeps

CTA_done:
    pop 07h
    pop 06h
    pop 03h
    pop 02h
    pop dph
    pop dpl
    pop b
    pop psw
    pop acc
    ret
   
   
send_all_serial_3digits:
    push acc
    push b
    push dpl
    push dph

    ; -------- TEMP = t_hot / 100 (same as your working code) --------
    mov x+0, t_hot+0
    mov x+1, t_hot+1
    mov x+2, t_hot+2
    mov x+3, t_hot+3

    Load_y(100)
    lcall div32
    mov temp, x+0              ; integer degC (0..255)

    ; -------- print TEMP --------
    mov a, temp
    mov R4, a
    mov R3, #0
    mov R2, #0
HUND_LOOP_T:
    mov a, R3
    jnz HUND_SUB_T
    mov a, R4
    clr c
    subb a, #100
    jc  HUND_DONE_T
HUND_SUB_T:
    mov a, R4
    clr c
    subb a, #100
    mov R4, a
    mov a, R3
    subb a, #0
    mov R3, a
    inc R2
    sjmp HUND_LOOP_T
HUND_DONE_T:
    mov a, R2
    add a, #'0'
    lcall putchar
    mov a, R4
    mov b, #10
    div ab
    add a, #'0'
    lcall putchar
    mov a, b
    add a, #'0'
    lcall putchar

    mov a, #' '
    lcall putchar

    ; -------- print temp_soak --------
    mov a, temp_soak
    mov R4, a
    mov R3, #0
    mov R2, #0
HUND_LOOP_SOT:
    mov a, R3
    jnz HUND_SUB_SOT
    mov a, R4
    clr c
    subb a, #100
    jc  HUND_DONE_SOT
HUND_SUB_SOT:
    mov a, R4
    clr c
    subb a, #100
    mov R4, a
    mov a, R3
    subb a, #0
    mov R3, a
    inc R2
    sjmp HUND_LOOP_SOT
HUND_DONE_SOT:
    mov a, R2
    add a, #'0'
    lcall putchar
    mov a, R4
    mov b, #10
    div ab
    add a, #'0'
    lcall putchar
    mov a, b
    add a, #'0'
    lcall putchar

    mov a, #' '
    lcall putchar

    ; -------- print time_soak --------
    mov a, time_soak
    mov R4, a
    mov R3, #0
    mov R2, #0
HUND_LOOP_SOK:
    mov a, R3
    jnz HUND_SUB_SOK
    mov a, R4
    clr c
    subb a, #100
    jc  HUND_DONE_SOK
HUND_SUB_SOK:
    mov a, R4
    clr c
    subb a, #100
    mov R4, a
    mov a, R3
    subb a, #0
    mov R3, a
    inc R2
    sjmp HUND_LOOP_SOK
HUND_DONE_SOK:
    mov a, R2
    add a, #'0'
    lcall putchar
    mov a, R4
    mov b, #10
    div ab
    add a, #'0'
    lcall putchar
    mov a, b
    add a, #'0'
    lcall putchar

    mov a, #' '
    lcall putchar

    ; -------- print temp_refl --------
    mov a, temp_refl
    mov R4, a
    mov R3, #0
    mov R2, #0
HUND_LOOP_RFT:
    mov a, R3
    jnz HUND_SUB_RFT
    mov a, R4
    clr c
    subb a, #100
    jc  HUND_DONE_RFT
HUND_SUB_RFT:
    mov a, R4
    clr c
    subb a, #100
    mov R4, a
    mov a, R3
    subb a, #0
    mov R3, a
    inc R2
    sjmp HUND_LOOP_RFT
HUND_DONE_RFT:
    mov a, R2
    add a, #'0'
    lcall putchar
    mov a, R4
    mov b, #10
    div ab
    add a, #'0'
    lcall putchar
    mov a, b
    add a, #'0'
    lcall putchar

    mov a, #' '
    lcall putchar

    ; -------- print time_refl --------
    mov a, time_refl
    mov R4, a
    mov R3, #0
    mov R2, #0
HUND_LOOP_RFK:
    mov a, R3
    jnz HUND_SUB_RFK
    mov a, R4
    clr c
    subb a, #100
    jc  HUND_DONE_RFK
HUND_SUB_RFK:
    mov a, R4
    clr c
    subb a, #100
    mov R4, a
    mov a, R3
    subb a, #0
    mov R3, a
    inc R2
    sjmp HUND_LOOP_RFK
HUND_DONE_RFK:
    mov a, R2
    add a, #'0'
    lcall putchar
    mov a, R4
    mov b, #10
    div ab
    add a, #'0'
    lcall putchar
    mov a, b
    add a, #'0'
    lcall putchar

    ; -------- CRLF --------
    mov a, #0Dh
    lcall putchar
    mov a, #0Ah
    lcall putchar

    pop dph
    pop dpl
    pop b
    pop acc
    ret
    
Serial_Command_Service:
    push acc
    push b
    push psw

    jnb RI, SCS_done

    mov a, SBUF
    clr RI
    mov b, a

    ; ---- bit0: ABORT ----
    mov a, b
    anl a, #01h
    jz  SCS_check_start

    ; Do the same “stop now” behavior your abort should do
    mov pwm, #0
    clr SSR_PIN
    mov FSM1_state, #5        ; your code: state 5 is the end/cooldown/stop state
    mov beep_count, #10       ; optional: trigger beeps (safe, small)
    sjmp SCS_done

SCS_check_start:
    ; ---- bit1: START (only from state 0) ----
    mov a, b
    anl a, #02h
    jz  SCS_done

    mov a, FSM1_state
    jnz SCS_done

    mov sec, #0
    clr Reached50_flag
    mov FSM1_state, #1
    lcall PlaySingle_beep        ; optional “start beep”

SCS_done:
    pop psw
    pop b
    pop acc
    ret
 




end