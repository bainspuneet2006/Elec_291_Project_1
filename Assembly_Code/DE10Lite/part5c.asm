; NOTE: ADD THIS CODE AFTER T_7seg in the main project code
; NOTE: In the main project code where it says Set_Cursor(1,14), replace lcall Display_BCD_7_Seg with lcall Display_TempC_7seg


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
