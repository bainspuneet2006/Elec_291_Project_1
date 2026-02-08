; ============================================================
; PROJECT 5A + OVEN FSM (MERGED FULL CODE)
; DE10-Lite CV-8052 (MODMAX10)
;
; MERGE FEATURES:
; 1) LCD UI pages + Page Button (P1.3 active-low) : HOME/SOAK/REFLOW
; 2) Keypad edits 3-digit value; '*' clears; '#' commits
; 3) SW1:SW0 (SWA.1:SWA.0) selects which parameter to edit:
;      00 temp_soak, 01 time_soak, 10 temp_refl, 11 time_refl
; 4) HARD RULE: parameter commit ONLY allowed when FSM1_state == 1
; 5) Keeps your latter oven code: PWM SSR on P2.0, ADC->mV->Temp, UART prints temp+state
; 6) Removes old UPDOWN/BCD counter logic (conflicts with SW1:SW0)
;
; NOTE:
; - If your keypad routine name differs, ONLY change Read_Keypad wrapper label.
; - Play_beeps_Switch moved to SWA.3 to avoid conflict with PARAM_SEL bits.
; ============================================================

$NOLIST
$MODMAX10
$LIST

; ----------------------------
; CLOCK / TIMERS
; ----------------------------
CLK           EQU 33333333
TIMER0_RATE   EQU 4096
TIMER0_RELOAD EQU ((65536-(CLK/(12*TIMER0_RATE))))
TIMER2_RATE   EQU 1000
TIMER2_RELOAD EQU ((65536-(CLK/(12*TIMER2_RATE))))

; ----------------------------
; PINS / IO
; ----------------------------
SOUND_OUT     equ P1.5

; SW1:SW0 select parameter being edited
PARAM_SEL0    equ SWA.0   ; SW0
PARAM_SEL1    equ SWA.1   ; SW1

Start_Switch  equ SWA.2

; optional beep-enable switch (moved off SWA.1 because SWA.1 is PARAM_SEL1)
Play_beeps_Switch equ SWA.3

; Page button (active-low to GND)
PAGE_BTN      equ P1.3

; SSR pin (active-low)
SSR_PIN       equ P2.0

; ----------------------------
; UART
; ----------------------------
BAUD            EQU 57600
TIMER_1_RELOAD  EQU (256-((2*CLK)/(12*32*BAUD)))

; ----------------------------
; VECTORS
; ----------------------------
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


; ============================================================
; DATA
; ============================================================
dseg at 0x30

Count1ms:     ds 2
count_ms:     ds 2

beep_count:   ds 1

FSM1_state:   ds 1

temp_soak:    ds 1
time_soak:    ds 1
temp_refl:    ds 1
time_refl:    ds 1

pwm_counter:  ds 1
pwm:          ds 1

temp:         ds 1
sec:          ds 1

x:            ds 4
y:            ds 4
bcd:          ds 5

V_amp_mv:     ds 4
T_cold:       ds 4
t_hot:        ds 4
VAL_LM4040:   ds 2

; ---- UI / keypad vars ----
ui_page:        ds 1   ; 0 HOME, 1 SOAK, 2 REFLOW
edit_d0:        ds 1
edit_d1:        ds 1
edit_d2:        ds 1
edit_count:     ds 1
last_key:       ds 1
page_btn_last:  ds 1   ; 1 released, 0 pressed


; ============================================================
; BITS
; ============================================================
bseg
half_seconds_flag: dbit 1
Reached50_flag:     dbit 1
ui_dirty:           dbit 1


; ============================================================
; CODE / INCLUDES
; ============================================================
cseg

; LCD wiring (DE10-Lite common wiring used in your code)
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


; ============================================================
; TIMER0 (speaker square wave)
; ============================================================
Timer0_Init:
    mov a, TMOD
    anl a, #0F0h
    orl a, #01h
    mov TMOD, a
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)
    setb ET0
    clr TR0           ; start OFF
    ret

Timer0_ISR:
    mov TH0, #high(TIMER0_RELOAD)
    mov TL0, #low(TIMER0_RELOAD)
    cpl SOUND_OUT
    reti


; ============================================================
; TIMER2 (1ms tick + PWM + time + half-second flag + beep gating)
; ============================================================
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

    setb ET2
    setb TR2
    ret

Timer2_ISR:
    clr TF2
    push acc
    push psw
    push b
    push dpl
    push dph

    ; ---- PWM (0..99 counter) ----
    inc pwm_counter
    mov a, pwm_counter
    cjne a, #100, do_pwm_check
    mov pwm_counter, #0

do_pwm_check:
    clr c
    mov a, pwm_counter
    subb a, pwm
    jc _ssr_on

_ssr_off:
    setb SSR_PIN       ; active-low OFF
    sjmp _pwm_done

_ssr_on:
    clr SSR_PIN        ; active-low ON

_pwm_done:

    ; ---- timekeeping ----
    inc Count1ms+0
    mov a, Count1ms+0
    jnz _inc_ms
    inc Count1ms+1

_inc_ms:
    inc count_ms+0
    mov a, count_ms+0
    jnz _check_1s
    inc count_ms+1

_check_1s:
    mov a, count_ms+0
    cjne a, #low(1000), _check_500ms
    mov a, count_ms+1
    cjne a, #high(1000), _check_500ms

    inc sec
    clr a
    mov count_ms+0, a
    mov count_ms+1, a

_check_500ms:
    mov a, Count1ms+0
    cjne a, #low(500), _beep_logic
    mov a, Count1ms+1
    cjne a, #high(500), _beep_logic

    clr a
    mov Count1ms+0, a
    mov Count1ms+1, a
    setb half_seconds_flag
    cpl LEDRA.0

_beep_logic:
    ; beep_count > 0 => enable TR0 for short burst at start of each half-second
    mov a, beep_count
    jz _beep_off

    ; Beep ON for first 100ms of each half-second window
    mov a, Count1ms+1
    jnz _beep_off
    mov a, Count1ms+0
    cjne a, #100, _beep_under100
    sjmp _beep_off

_beep_under100:
    jc _beep_on

_beep_off:
    clr TR0
    clr SOUND_OUT
    sjmp _done_isr

_beep_on:
    setb TR0

_done_isr:
    pop dph
    pop dpl
    pop b
    pop psw
    pop acc
    reti


; ============================================================
; 7-seg lookup
; ============================================================
T_7seg:
    DB 0xC0, 0xF9, 0xA4, 0xB0, 0x99
    DB 0x92, 0x82, 0xF8, 0x80, 0x90
    DB 0x88, 0x83, 0xC6, 0xA1, 0x86, 0x8E


; ============================================================
; UART init / putchar / SendString
; ============================================================
Initialize_Serial_Port:
    clr TR1
    anl TMOD, #0x0F
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


; ============================================================
; Beep helpers (set count, ISR makes the sound)
; ============================================================
playSingle_beep:
    mov beep_count, #1
    ret

five_beeps:
    mov beep_count, #5
    ret

ten_beeps:
    mov beep_count, #10
    ret


; ============================================================
; UI: Page button task
; ============================================================
UI_PageButton_Task:
    push acc

    ; read button (released=1, pressed=0)
    mov c, PAGE_BTN
    mov a, #0
    jnc _btn_pressed_now
    mov a, #1
_btn_pressed_now:

    ; edge detect
    cjne a, page_btn_last, _changed
    sjmp _pb_done

_changed:
    mov page_btn_last, a
    jnz _pb_done             ; only act on press (a==0)

    ; debounce confirm still pressed
    Wait_Milli_Seconds(#50)
    jb PAGE_BTN, _pb_done

    ; advance page
    mov a, ui_page
    inc a
    cjne a, #3, _store
    mov a, #0
_store:
    mov ui_page, a
    setb ui_dirty

    ; wait release (prevents double advance)
_wait_rel:
    jnb PAGE_BTN, _wait_rel

_pb_done:
    pop acc
    ret


; ============================================================
; UI: Keypad wrapper (EDIT ONLY THIS if your keypad label differs)
; Return: A = ASCII key, 0FFh if no key
; ============================================================
Read_Keypad:
    ; CHANGE THIS ONE CALL if needed:
    lcall Read_keypad
    ret


; ============================================================
; UI: Keypad task (EDIT/COMMIT ONLY when FSM1_state == 1)
; ============================================================
UI_Keypad_Task:
    push acc
    push psw
    push b

    ; Only allow edits in FSM state 1
    mov a, FSM1_state
    cjne a, #1, _no_edit_allowed

    lcall Read_Keypad

    cjne a, #0FFh, _have_key
    mov last_key, #0FFh
    sjmp _kt_done

_have_key:
    mov b, last_key
    cjne a, b, _new_key
    sjmp _kt_done

_new_key:
    mov last_key, a

    ; digit?
    cjne a, #'0', _k1
    sjmp _is_digit
_k1:
    jc _chk_hash
    cjne a, #'9'+1, _chk_hash
    jc _is_digit

_chk_hash:
    mov a, last_key
    cjne a, #'#', _chk_star

    lcall UI_Commit_3Digits_To_SelectedParam
    mov edit_d0, #'0'
    mov edit_d1, #'0'
    mov edit_d2, #'0'
    mov edit_count, #0
    setb ui_dirty
    sjmp _kt_done

_chk_star:
    cjne a, #'*', _kt_done
    mov edit_d0, #'0'
    mov edit_d1, #'0'
    mov edit_d2, #'0'
    mov edit_count, #0
    setb ui_dirty
    sjmp _kt_done

_is_digit:
    mov a, edit_count
    cjne a, #0, _d1
    mov a, last_key
    mov edit_d0, a
    mov edit_count, #1
    setb ui_dirty
    sjmp _kt_done
_d1:
    cjne a, #1, _d2
    mov a, last_key
    mov edit_d1, a
    mov edit_count, #2
    setb ui_dirty
    sjmp _kt_done
_d2:
    cjne a, #2, _d_full
    mov a, last_key
    mov edit_d2, a
    mov edit_count, #3
    setb ui_dirty
    sjmp _kt_done

_d_full:
    ; shift left, keep 3 digits
    mov a, edit_d1
    mov edit_d0, a
    mov a, edit_d2
    mov edit_d1, a
    mov a, last_key
    mov edit_d2, a
    mov edit_count, #3
    setb ui_dirty
    sjmp _kt_done

_no_edit_allowed:
    ; Not state 1: ignore keypad and clear buffer
    mov last_key, #0FFh
    mov edit_d0, #'0'
    mov edit_d1, #'0'
    mov edit_d2, #'0'
    mov edit_count, #0

_kt_done:
    pop b
    pop psw
    pop acc
    ret


; ============================================================
; Commit "ddd" to selected param (SW1:SW0)
; ============================================================
UI_Commit_3Digits_To_SelectedParam:
    push acc
    push b
    push psw

    ; value = (d0-'0')*100 + (d1-'0')*10 + (d2-'0')
    mov a, edit_d0
    clr c
    subb a, #'0'
    mov b, #100
    mul ab
    mov R6, a

    mov a, edit_d1
    clr c
    subb a, #'0'
    mov b, #10
    mul ab
    add a, R6
    mov R6, a

    mov a, edit_d2
    clr c
    subb a, #'0'
    add a, R6
    mov R6, a

    ; sel = (SW1<<1) | SW0
    mov a, #0
    jb PARAM_SEL0, _s0_1
    sjmp _s0_0
_s0_1:
    orl a, #01h
_s0_0:
    jb PARAM_SEL1, _s1_1
    sjmp _sel_done
_s1_1:
    orl a, #02h
_sel_done:

    cjne a, #0, _p1
    mov temp_soak, R6
    sjmp _cdone
_p1:
    cjne a, #1, _p2
    mov time_soak, R6
    sjmp _cdone
_p2:
    cjne a, #2, _p3
    mov temp_refl, R6
    sjmp _cdone
_p3:
    mov time_refl, R6

_cdone:
    pop psw
    pop b
    pop acc
    ret


; ============================================================
; UI Render
; ============================================================
UI_Render_LCD:
    push acc
    push psw

    lcall ELCD_4BIT_CLEAR

    mov a, ui_page
    cjne a, #0, _draw_soak

    Set_Cursor(1,1)
    Send_Constant_String(#HomeStr)
    sjmp _r_done

_draw_soak:
    cjne a, #1, _draw_reflow

    Set_Cursor(1,1)
    Send_Constant_String(#SoakStr)

    Set_Cursor(2,1)
    mov a, temp_soak
    lcall UI_Print3DecA
    Send_Constant_String(#DegCStr)

    Set_Cursor(2,10)
    mov a, time_soak
    lcall UI_Print3DecA
    Send_Constant_String(#SecStr)
    sjmp _r_done

_draw_reflow:
    Set_Cursor(1,1)
    Send_Constant_String(#ReflowStr)

    Set_Cursor(2,1)
    mov a, temp_refl
    lcall UI_Print3DecA
    Send_Constant_String(#DegCStr)

    Set_Cursor(2,10)
    mov a, time_refl
    lcall UI_Print3DecA
    Send_Constant_String(#SecStr)

_r_done:
    pop psw
    pop acc
    ret

UI_Print3DecA:
    push acc
    push b

    mov b, #100
    div ab
    add a, #'0'
    lcall ELCD_4BIT_SEND_DATA

    mov a, b
    mov b, #10
    div ab
    add a, #'0'
    lcall ELCD_4BIT_SEND_DATA

    mov a, b
    add a, #'0'
    lcall ELCD_4BIT_SEND_DATA

    pop b
    pop acc
    ret

HomeStr:   db 'HOME',0
SoakStr:   db 'SOAK',0
ReflowStr: db 'REFLOW',0
DegCStr:   db ' C',0
SecStr:    db 's',0


; ============================================================
; FSM1 (OVEN FSM) - uses temp/time params + pwm
; ============================================================
FSM1:
    mov a, FSM1_state

FSM_state0:
    cjne a, #0, FSM1_state1
    mov pwm, #0
    jb Start_Switch, FSM1_state0_done
    lcall playSingle_beep
    mov sec, #0
    clr Reached50_flag
    mov FSM1_state, #1
FSM1_state0_done:
    ljmp FSM2

FSM1_state1:
    cjne a, #1, FSM1_state2
    mov pwm, #100

    ; latch if temp >= 50
    mov a, temp
    clr c
    subb a, #50
    jc  _below50
    setb Reached50_flag
_below50:

    ; if sec>=60 and never reached 50 => error
    mov a, sec
    clr c
    subb a, #60
    jc _continue_preheat
    jb Reached50_flag, _continue_preheat

    mov pwm, #0
    mov FSM1_state, #6
    lcall ten_beeps
    ljmp FSM2

_continue_preheat:
    mov a, temp_soak
    clr c
    subb a, temp
    jnc _s1_done
    mov sec, #0
    mov FSM1_state, #2
    lcall playSingle_beep
_s1_done:
    ljmp FSM2

FSM1_state2:
    cjne a, #2, FSM1_state3
    mov pwm, #20
    mov a, time_soak
    clr c
    subb a, sec
    jnc _s2_done
    mov FSM1_state, #3
    lcall playSingle_beep
_s2_done:
    ljmp FSM2

FSM1_state3:
    cjne a, #3, FSM1_state4
    mov pwm, #100
    mov sec, #0
    mov a, temp_refl
    clr c
    subb a, temp
    jnc _s3_done
    mov FSM1_state, #4
    lcall playSingle_beep
_s3_done:
    ljmp FSM2

FSM1_state4:
    cjne a, #4, FSM1_state5
    mov pwm, #20
    mov a, time_refl
    clr c
    subb a, sec
    jnc _s4_done
    mov FSM1_state, #5
    lcall playSingle_beep
_s4_done:
    ljmp FSM2

FSM1_state5:
    cjne a, #5, FSM1_state6
    mov pwm, #0
    mov a, temp
    clr c
    subb a, #60
    jnc _s5_done
    mov FSM1_state, #0
_s5_done:
    ljmp FSM2

FSM1_state6:
    cjne a, #6, FSM_state0
    mov pwm, #0
    jb Start_Switch, _err_done
    ljmp FSM2
_err_done:
    mov FSM1_state, #0
    ljmp FSM2


; ============================================================
; ADC / TEMP / DISPLAY / SERIAL (from your latter code)
; ============================================================

Read_ADC:
    mov ADC_C, a
    mov R1, ADC_H
    mov R0, ADC_L
    ret

Read_Ref:
    mov a, #00h
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

    ; x = ADC_opamp
    mov x+0, R0
    mov x+1, R1
    mov x+2, #00h
    mov x+3, #00h

    ; x = x * 2500   (because your reference is 2.5V/LM4040 chain)
    Load_y(2500)
    lcall mul32

    ; y = ADC_ref
    mov y+0, VAL_LM4040+0
    mov y+1, VAL_LM4040+1
    mov y+2, #00h
    mov y+3, #00h

    ; x = (ADC_opamp * 2500) / ADC_ref  => mV
    lcall div32

    mov V_amp_mv+0, x+0
    mov V_amp_mv+1, x+1
    mov V_amp_mv+2, x+2
    mov V_amp_mv+3, x+3
    ret

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
    lcall div32

    ; add cold junction temp (centi-°C)
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


; ---- Display integer °C on HEX2 HEX1 HEX0 ----
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

    ; x = x / 100 -> integer °C
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


; ---- Send temperature over UART as 3 digits + CRLF ----
send_temp_serial:
    ; x = t_hot / 100 -> integer °C
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


; ============================================================
; MAIN
; ============================================================
main:
    mov SP, #060h
    mov FSM1_state, #0

    ; Page button pull-up (quasi-bidir input)
    setb P1.3

    ; Defaults for parameters (can be edited ONLY in FSM state 1)
    mov temp_soak,  #150
    mov time_soak,  #60
    mov temp_refl,  #220
    mov time_refl,  #45

    ; UI defaults
    mov ui_page, #0
    mov page_btn_last, #1
    mov edit_d0, #'0'
    mov edit_d1, #'0'
    mov edit_d2, #'0'
    mov edit_count, #0
    mov last_key, #0FFh
    setb ui_dirty

    ; init timers + uart
    lcall Timer0_Init
    lcall Timer2_Init
    lcall Initialize_Serial_Port

    ; IO modes
    mov P0MOD, #10101010b
    mov P1MOD, #10100010b     ; P1.7/P1.5/P1.1 outputs, P1.3 input (bit3=0)
    mov P2MOD, #0FFh
    mov P3MOD, #0FFh

    mov LEDRA, #0
    mov LEDRB, #0

    setb EA

    lcall ELCD_4BIT
    lcall ELCD_4BIT_CLEAR

    ; cold junction constant (your existing value)
    mov T_cold+0, #098h
    mov T_cold+1, #008h
    mov T_cold+2, #000h
    mov T_cold+3, #000h

    mov ADC_C, #080h
    Wait_Milli_Seconds(#50)

; ============================================================
; FSM2 main loop (UI + sensing + serial + FSM1)
; ============================================================
FSM2:

    ; ---- UI tasks always run ----
    lcall UI_PageButton_Task
    lcall UI_Keypad_Task

    ; render only when dirty
    jb ui_dirty, _ui_do_render
    sjmp _ui_skip_render
_ui_do_render:
    clr ui_dirty
    lcall UI_Render_LCD
_ui_skip_render:

    ; ---- Optional: test beep enable (only if switch on) ----
    jnb Play_beeps_Switch, _skip_beep_test
    jnb half_seconds_flag, _skip_beep_test
    lcall playSingle_beep
_skip_beep_test:

    ; ---- Key1 reset logic (kept) ----
    jb KEY.1, loop_a
    Wait_Milli_Seconds(#50)
    jb KEY.1, loop_a
    jnb KEY.1, $
    clr TR2
    clr a
    mov Count1ms+0, a
    mov Count1ms+1, a
    setb TR2

loop_a:
    jnb half_seconds_flag, loop_a2
loop_a2:
    ; DO NOT clear half_seconds_flag here if you rely on it elsewhere
    ; (your original code cleared it in loop_b; leaving as your style)
    clr half_seconds_flag

    ; ---- sensor reads / compute temp ----
    lcall Read_Ref
    lcall Read_op_amp_mv
    lcall VoutmV_To_TempC

    ; ---- 7-seg display ----
    lcall Display_TempC_7Seg

    ; ---- UART output ----
    lcall send_temp_serial
    lcall PrintStateSerial

    ; ---- go run FSM ----
    ljmp FSM1


end
