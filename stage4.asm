; stage4.asm - KindOS Mouse Driver [Kindrel V22 ABI + IRQ12 FIX + REAL COUNTERS]
BITS 32
ORG 0x120000

; ====================== MODULE HEADER ======================
module_base:
    dw 0x4F4D                      ; SIG_STAGE4 'MO'
    dw 1                           ; version
    dd stage4_end - module_base    ; size
    dd mouse_init - module_base    ; entry point (relative)
    dd 0                           ; flags
    dd mouse_isr - module_base     ; IRQ12 entry (relative)
    dd 0, 0, 0                     ; reserved

%define PS2_DATA_PORT    0x60
%define PS2_STATUS_PORT  0x64
%define PS2_CMD_PORT     0x64
%define PS2_OUTPUT_FULL  0x01
%define PS2_INPUT_FULL   0x02
%define PS2_MOUSE_DATA   0x20

%define MOUSE_CMD_RESET       0xFF
%define MOUSE_CMD_DEFAULTS    0xF6
%define MOUSE_CMD_ENABLE      0xF4
%define MOUSE_CMD_SET_RATE    0xF3
%define MOUSE_CMD_SET_RES     0xE8
%define MOUSE_ACK             0xFA
%define MOUSE_RESEND          0xFE
%define MOUSE_SELFTEST_OK     0xAA
%define TIMEOUT_COUNT         0xFFFF

; --- Экспорт-таблица (смещения в байтах от начала таблицы) ---
%define EXPORT_MOUSE_X        20
%define EXPORT_MOUSE_Y        24
%define EXPORT_MOUSE_BUTTONS  28
%define EXPORT_SCREEN_W       32
%define EXPORT_SCREEN_H       36
%define EXPORT_ISR_COUNTER    60   ; Новое поле (сдвинуто с 40 во избежание конфликта)
%define EXPORT_PKT_COUNTER    64   ; Новое поле (сдвинуто с 44 во избежание конфликта)

; ====================== DATA ======================
export_table_ptr     dd 0
mouse_present        db 0
mouse_error          db 0
mouse_cycle          db 0
mouse_packet         times 3 db 0
mouse_buttons_state  db 0

isr_counter          dd 0          ; Честный счётчик IRQ12
pkt_counter          dd 0          ; Честный счётчик собранных пакетов
packets_lost         dd 0
resend_count         dd 0
error_count          dd 0

; ====================== CODE ======================
mouse_init:
    push ebx
    push ecx
    push edx
    push esi
    push edi

    mov [export_table_ptr], eax

    ; --- Инициализация переменных ---
    mov byte [mouse_present], 0
    mov byte [mouse_error], 0
    mov byte [mouse_cycle], 0
    mov dword [isr_counter], 0
    mov dword [pkt_counter], 0
    mov dword [packets_lost], 0
    mov dword [resend_count], 0
    mov dword [error_count], 0

    ; --- Enable auxiliary device (mouse) ---
    call ps2_wait_write
    jc .init_error

    mov al, 0xA8
    out PS2_CMD_PORT, al

    mov ecx, 0x1000
.pause1:
    loop .pause1

    ; --- Read config byte ---
    call ps2_wait_write
    jc .init_error

    mov al, 0x20
    out PS2_CMD_PORT, al

    call ps2_wait_read
    jc .init_error

    in al, PS2_DATA_PORT
    ; --- Модифицируем config byte: включаем IRQ12 и clock ---
    or al, 0x02                ; set bit 1 -> IRQ12 enable
    and al, 0xDF               ; clear bit 5 -> mouse clock enable
    mov bl, al                 ; СОХРАНЯЕМ МОДИФИЦИРОВАННЫЙ БАЙТ

    ; --- Write modified config byte back ---
    call ps2_wait_write
    jc .init_error

    mov al, 0x60
    out PS2_CMD_PORT, al

    call ps2_wait_write
    jc .init_error

    mov al, bl                 ; ИСПРАВЛЕНО: пишем модифицированный байт
    out PS2_DATA_PORT, al

    ; --- Reset mouse ---
    mov al, MOUSE_CMD_RESET
    call mouse_send_command
    cmp al, MOUSE_ACK
    jne .init_error

    ; --- Read self-test result (0xAA = OK) ---
    call ps2_wait_read
    jc .init_error
    in al, PS2_DATA_PORT
    cmp al, MOUSE_SELFTEST_OK  ; ИСПРАВЛЕНО: проверяем self-test
    jne .init_error

    ; --- Read device ID (0x00 = standard mouse) ---
    call ps2_wait_read
    jc .init_error
    in al, PS2_DATA_PORT

    ; --- Set resolution ---
    mov al, MOUSE_CMD_SET_RES
    call mouse_send_command
    cmp al, MOUSE_ACK
    jne .init_error

    mov al, 3
    call mouse_send_command
    cmp al, MOUSE_ACK
    jne .init_error

    ; --- Set sample rate ---
    mov al, MOUSE_CMD_SET_RATE
    call mouse_send_command
    cmp al, MOUSE_ACK
    jne .init_error

    mov al, 100
    call mouse_send_command
    cmp al, MOUSE_ACK
    jne .init_error

    ; --- Enable data reporting ---
    mov al, MOUSE_CMD_ENABLE
    call mouse_send_command
    cmp al, MOUSE_ACK
    jne .init_error

    mov byte [mouse_present], 1
    mov byte [mouse_cycle], 0

    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    mov eax, 1
    ret

.init_error:
    mov byte [mouse_error], 1
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    xor eax, eax
    ret

; ====================== ISR ======================
mouse_isr:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi

    ; --- ЧЕСТНЫЙ счётчик вызовов ISR ---
    inc dword [isr_counter]
    mov eax, [isr_counter]
    cmp eax, 10000
    jb .no_cap
    mov eax, 10000
    mov [isr_counter], eax
.no_cap:

    in al, PS2_STATUS_PORT
    test al, PS2_OUTPUT_FULL
    jz .done
    test al, PS2_MOUSE_DATA
    jz .done

    in al, PS2_DATA_PORT
    mov cl, al

    mov dl, [mouse_cycle]
    cmp dl, 0
    je .state_0
    cmp dl, 1
    je .state_1
    cmp dl, 2
    je .state_2
    jmp .reset_fsm

.state_0:
    test cl, 0x08
    jz .discard
    mov [mouse_packet], cl
    mov byte [mouse_cycle], 1
    jmp .done

.discard:
    inc dword [packets_lost]
    jmp .done

.state_1:
    mov [mouse_packet + 1], cl
    mov byte [mouse_cycle], 2
    jmp .done

.state_2:
    mov [mouse_packet + 2], cl
    mov byte [mouse_cycle], 0
    
    mov edx, [export_table_ptr]

    ; --- Всегда обновляем кнопки (даже если overflow) ---
    test edx, edx
    jz .no_buttons
    mov eax, [edx + EXPORT_MOUSE_BUTTONS]
    mov bl, [mouse_packet]
    and bl, 0x07
    mov [eax], bl
    mov [mouse_buttons_state], bl
.no_buttons:

    ; --- Проверка overflow (биты 6 и 7) ---
    mov bl, [mouse_packet]
    test bl, 0xC0
    jnz .overflow

    ; --- Пакет валиден, увеличиваем счётчик ---
    inc dword [pkt_counter]
    mov eax, [pkt_counter]
    cmp eax, 10000
    jb .pkt_cap
    mov eax, 10000
    mov [pkt_counter], eax
.pkt_cap:

    test edx, edx
    jz .done

    ; --- Обновляем X ---
    mov edi, [edx + EXPORT_MOUSE_X]
    mov esi, [edx + EXPORT_SCREEN_W]
    mov ebx, [esi]
    movsx eax, byte [mouse_packet + 1]
    add [edi], eax

    cmp dword [edi], 0
    jge .check_max_x
    mov dword [edi], 0
.check_max_x:
    dec ebx
    cmp [edi], ebx
    jle .apply_y
    mov [edi], ebx

.apply_y:
    ; --- Обновляем Y (инвертированно) ---
    mov edi, [edx + EXPORT_MOUSE_Y]
    mov esi, [edx + EXPORT_SCREEN_H]
    mov ecx, [esi]
    movsx eax, byte [mouse_packet + 2]
    sub [edi], eax

    cmp dword [edi], 0
    jge .check_max_y
    mov dword [edi], 0
.check_max_y:
    dec ecx
    cmp [edi], ecx
    jle .done
    mov [edi], ecx
    jmp .done

.overflow:
    inc dword [packets_lost]
    jmp .done

.reset_fsm:
    mov byte [mouse_cycle], 0

.done:
    mov al, 0x20
    out 0xA0, al
    out 0x20, al

    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    iretd

; ====================== UTILS ======================
mouse_get_state:
    mov al, [mouse_present]
    mov ah, [mouse_error]
    ret

mouse_reset:
    push eax
    mov byte [mouse_cycle], 0
    mov byte [mouse_buttons_state], 0
    mov dword [isr_counter], 0
    mov dword [pkt_counter], 0
    mov dword [packets_lost], 0
    pop eax
    ret

ps2_wait_write:
    push eax
    push ecx
    mov ecx, TIMEOUT_COUNT
.wait:
    in al, PS2_STATUS_PORT
    test al, PS2_INPUT_FULL
    jz .ready
    loop .wait
    stc
    jmp .done
.ready:
    clc
.done:
    pop ecx
    pop eax
    ret

ps2_wait_read:
    push eax
    push ecx
    mov ecx, TIMEOUT_COUNT
.wait:
    in al, PS2_STATUS_PORT
    test al, PS2_OUTPUT_FULL
    jnz .ready
    loop .wait
    stc
    jmp .done
.ready:
    clc
.done:
    pop ecx
    pop eax
    ret

mouse_send_command:
    push ecx
    push edx
    mov dl, al
    call ps2_wait_write
    jc .error
    mov al, 0xD4
    out PS2_CMD_PORT, al
    call ps2_wait_write
    jc .error
    mov al, dl
    out PS2_DATA_PORT, al
.retry:
    call ps2_wait_read
    jc .error
    in al, PS2_DATA_PORT
    cmp al, MOUSE_RESEND
    je .do_resend
    cmp al, MOUSE_ACK
    je .done
    jmp .error
.do_resend:
    inc dword [resend_count]
    call ps2_wait_write
    jc .error
    mov al, 0xD4
    out PS2_CMD_PORT, al
    call ps2_wait_write
    jc .error
    mov al, dl
    out PS2_DATA_PORT, al
    jmp .retry
.error:
    inc dword [error_count]
    mov al, 0xFF
.done:
    pop edx
    pop ecx
    ret

stage4_end equ $