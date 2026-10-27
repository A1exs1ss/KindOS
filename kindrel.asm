; ======================================================================
;  KINDREL - KindOS Kernel (Combined Stage3) [CLEAN BUILD + SCENE + ANIMALS]
;  ABI: EBP = база ядра (0x100000), EBX свободен
; ======================================================================

BITS 16
ORG 0x0000

; ======================================================================
;  КОНСТАНТЫ
; ======================================================================
%define SECTOR_SIZE 512
%define CODE_SEL 0x08
%define DATA_SEL 0x10
%define KERNEL_BASE 0x100000
%define KERNEL_STACK_TOP 0x1F0000
%define RM_STACK_SEG 0x0000
%define RM_STACK_SP  0x7C00

%define LOADER_BASE 0x10000
%define PM_LOADER_STACK_TOP 0x70000

%define STAGE4_ADDR 0x120000
%define STAGE5_ADDR 0x130000
%define STAGE6_ADDR 0x140000

%define SIG_STAGE4 0x4F4D
%define SIG_STAGE5 0x4944
%define SIG_STAGE6 0x4D46

%define MOD_HEADER_SIG           0
%define MOD_HEADER_VERSION       2
%define MOD_HEADER_SIZE          4
%define MOD_HEADER_ENTRY         8
%define MOD_HEADER_FLAGS         12
%define MOD_HEADER_IRQ12_ENTRY   16
%define MOD_HEADER_RESERVED      20
%define MOD_HEADER_MIN_SIZE      32

%define STAGE_MAX_SIZE 0x10000

%define KINDREL_FILE_SIZE  0x18000
%define STAGE4_FILE_OFFSET 0x20000
%define STAGE5_FILE_OFFSET 0x30000
%define STAGE6_FILE_OFFSET 0x40000

%define INFO_BOOT_DRIVE   0x500
%define INFO_STAGE4_ADDR  0x505
%define INFO_STAGE5_ADDR  0x509
%define INFO_STAGE6_ADDR  0x50D
%define INFO_SCREEN_WIDTH 0x521
%define INFO_SCREEN_HEIGHT 0x523

; --- КОНСТАНТЫ ДЛЯ СЦЕНЫ ---
%define SKY_COLOR       0x0B    ; Ярко-голубое небо
%define SUN_COLOR       0x0E    ; Желтое солнце
%define SUN_X           280     ; Позиция солнца по X
%define SUN_Y           40      ; Позиция солнца по Y
%define SUN_R           20      ; Радиус солнца
%define GRASS_COLOR     0x0A    ; Салатовая трава
%define GRASS_HEIGHT    40      ; Высота травы
%define TASKBAR_COLOR   0x01    ; Темно-синяя панель задач
%define TASKBAR_HEIGHT  20      ; Высота панели задач

; ======================================================================
;  ТОЧКА ВХОДА ЗАГРУЗЧИКА (16-BIT)
; ======================================================================
loader_start:
    jmp 0x1000:.fix_cs
.fix_cs:
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ax, RM_STACK_SEG
    mov ss, ax
    mov sp, RM_STACK_SP
    mov [boot_drive], dl

    xor eax, eax
    mov ax, ds
    shl eax, 4
    mov [load_base], eax

    mov si, msg_start
    call print16
    call wait_key

    call enable_a20
    jc error_a20
    mov si, msg_a20_ok
    call print16
    call wait_key

    call test_a20
    jc error_a20_test
    mov si, msg_a20_test_ok
    call print16
    call wait_key

    mov si, msg_pm
    call print16
    call wait_key

    mov ax, 0x0013
    int 0x10
    mov ah, 0x0F
    int 0x10
    cmp al, 0x13
    jne vga_failed

    cli
    mov al, 0xFF
    out 0x21, al
    out 0xA1, al
    in al, 0x70
    or al, 0x80
    out 0x70, al
    in al, 0x71
    call safe_disable_apic

    mov eax, [load_base]
    add eax, gdt
    mov [gdt_desc + 2], eax
    mov word [gdt_desc], gdt_end - gdt - 1
    lgdt [gdt_desc]

    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword CODE_SEL:(LOADER_BASE + pm_flush)

vga_failed:
    mov si, err_vga
    call print16
    jmp error_halt

; ======================================================================
;  ЗАЩИЩЁННЫЙ РЕЖИМ (32-BIT, загрузчик)
; ======================================================================
BITS 32
pm_flush:
    mov ax, DATA_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, PM_LOADER_STACK_TOP
    cld

    mov eax, kernel_size
    cmp eax, KINDREL_FILE_SIZE
    ja .kernel_too_large

    mov esi, LOADER_BASE
    add esi, kernel_file_offset
    mov edi, KERNEL_BASE
    mov ecx, kernel_size
    shr ecx, 2
    rep movsd
    mov ecx, kernel_size
    and ecx, 3
    rep movsb

    ; STAGE4
    mov esi, LOADER_BASE + STAGE4_FILE_OFFSET
    mov edi, STAGE4_ADDR
    mov edx, SIG_STAGE4
    call copy_module

    ; STAGE5
    mov esi, LOADER_BASE + STAGE5_FILE_OFFSET
    mov edi, STAGE5_ADDR
    mov edx, SIG_STAGE5
    call copy_module

    ; STAGE6
    mov esi, LOADER_BASE + STAGE6_FILE_OFFSET
    mov edi, STAGE6_ADDR
    mov edx, SIG_STAGE6
    call copy_module

.finish:
    mov al, [LOADER_BASE + boot_drive]
    mov [INFO_BOOT_DRIVE], al
    mov dword [INFO_STAGE4_ADDR], STAGE4_ADDR
    mov dword [INFO_STAGE5_ADDR], STAGE5_ADDR
    mov dword [INFO_STAGE6_ADDR], STAGE6_ADDR
    mov word [INFO_SCREEN_WIDTH], 320
    mov word [INFO_SCREEN_HEIGHT], 200

    jmp CODE_SEL:KERNEL_BASE

.kernel_too_large:
.hang_big:
    hlt
    jmp .hang_big

; ======================================================================
;  КОПИРОВАНИЕ МОДУЛЯ
; ======================================================================
copy_module:
    push eax
    push ecx
    push edx

    cmp word [esi + MOD_HEADER_SIG], dx
    jne .invalid

    mov ecx, [esi + MOD_HEADER_SIZE]
    cmp ecx, MOD_HEADER_MIN_SIZE
    jb .invalid
    cmp ecx, STAGE_MAX_SIZE
    ja .invalid

    mov edx, ecx
    shr ecx, 2
    rep movsd
    mov ecx, edx
    and ecx, 3
    rep movsb

    clc
    jmp .done

.invalid:
    stc

.done:
    pop edx
    pop ecx
    pop eax
    ret

; ======================================================================
;  ФУНКЦИИ ЗАГРУЗЧИКА (16-BIT)
; ======================================================================
BITS 16

safe_disable_apic:
    pusha
    pushfd
    pop eax
    mov ecx, eax
    xor eax, (1 << 21)
    push eax
    popfd
    pushfd
    pop eax
    xor eax, ecx
    jz .no_cpuid

    mov eax, 1
    cpuid
    test edx, (1 << 9)
    jz .no_apic
    test edx, (1 << 5)
    jz .no_apic

    mov ecx, 0x1B
    rdmsr
    test eax, (1 << 11)
    jz .no_apic
    and eax, ~(1 << 11)
    wrmsr

.no_apic:
.no_cpuid:
    popa
    ret

wait_key:
    push ax
    mov ah, 0x00
    int 0x16
    pop ax
    ret

error_a20:
    mov si, err_a20
    call print16
    jmp error_halt

error_a20_test:
    mov si, err_a20_test
    call print16
    jmp error_halt

error_halt:
    xor ax, ax
    int 0x16
    int 0x19
.halt:
    hlt
    jmp .halt

enable_a20:
    mov ax, 0x2401
    int 0x15
    jnc .done
    cli
    call a20_wait
    jc .fail
    mov al, 0xAD
    out 0x64, al
    call a20_wait
    jc .fail
    mov al, 0xD0
    out 0x64, al
    call a20_wait_output
    jc .fail
    in al, 0x60
    push ax
    call a20_wait
    jc .fail
    mov al, 0xD1
    out 0x64, al
    call a20_wait
    jc .fail
    pop ax
    or al, 2
    out 0x60, al
    call a20_wait
    jc .fail
    mov al, 0xAE
    out 0x64, al
    call a20_wait
    jc .fail
.done:
    clc
    ret
.fail:
    stc
    ret

a20_wait:
    push cx
    mov cx, 0xFFFF
.loop:
    in al, 0x64
    test al, 2
    jz .ok
    loop .loop
    stc
    pop cx
    ret
.ok:
    clc
    pop cx
    ret

a20_wait_output:
    push cx
    mov cx, 0xFFFF
.loop:
    in al, 0x64
    test al, 1
    jnz .ok
    loop .loop
    stc
    pop cx
    ret
.ok:
    clc
    pop cx
    ret

test_a20:
    push ds
    push es
    push si
    push di
    push bx

    xor ax, ax
    mov ds, ax
    mov si, 0x0500
    mov ax, 0xFFFF
    mov es, ax
    mov di, 0x0510

    mov al, [ds:si]
    push ax
    mov al, [es:di]
    push ax

    mov byte [ds:si], 0xAA
    mov byte [es:di], 0x55

    mov al, [ds:si]
    mov bl, [es:di]
    cmp al, bl
    jne .a20_on

.a20_off:
    pop ax
    mov [es:di], al
    pop ax
    mov [ds:si], al
    stc
    jmp .done

.a20_on:
    pop ax
    mov [es:di], al
    pop ax
    mov [ds:si], al
    clc

.done:
    pop bx
    pop di
    pop si
    pop es
    pop ds
    ret

print16:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    mov bx, 0x000F
    int 0x10
    jmp print16
.done:
    ret

; ======================================================================
;  GDT
; ======================================================================
align 8
gdt:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd 0

; ======================================================================
;  ДАННЫЕ ЗАГРУЗЧИКА
; ======================================================================
msg_start db 'Kindrel: START', 13, 10, 0
msg_a20_ok db 'Kindrel: A20 enabled', 13, 10, 0
msg_a20_test_ok db 'Kindrel: A20 test passed', 13, 10, 0
msg_pm db 'Kindrel: Entering PM...', 13, 10, 0
err_a20 db 'Kindrel: A20 failed', 13, 10, 0
err_a20_test db 'Kindrel: A20 test failed', 13, 10, 0
err_vga db 'Kindrel: VGA mode failed', 13, 10, 0

load_base dd 0
boot_drive db 0

; ======================================================================
;  ФИКСИРОВАННОЕ СМЕЩЕНИЕ ЯДРА
; ======================================================================
times 0x8000 - ($ - $$) db 0
kernel_file_offset equ 0x8000

; ======================================================================
;  32-BIT ЯДРО
; ======================================================================
BITS 32

%define KREL(x) ((x) - kernel_entry)

kernel_entry:
    mov ebp, KERNEL_BASE

    mov ax, DATA_SEL
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, KERNEL_STACK_TOP
    cld

    mov dword [ebp + KREL(screen_width_data)], 320
    mov dword [ebp + KREL(screen_height_data)], 200

    ; --- Начальная позиция мыши — центр экрана ---
    mov dword [ebp + KREL(mouse_x_data)], 160
    mov dword [ebp + KREL(mouse_y_data)], 100

    lea eax, [ebp + KREL(setup_idt)]
    call eax
    lea eax, [ebp + KREL(remap_pic)]
    call eax

    call setup_export_table
    call init_stage4

    lea eax, [ebp + KREL(init_pit)]
    call eax
    lea eax, [ebp + KREL(graphics_init)]
    call eax
    lea eax, [ebp + KREL(keyboard_init)]
    call eax

    ; init_stage5 и init_stage6 — отключены (битые модули)
    ; call init_stage5
    ; call init_stage6

    mov dword [ebp + KREL(win_x_data)], 20
    mov dword [ebp + KREL(win_y_data)], 20
    mov dword [ebp + KREL(win_w_data)], 280
    mov dword [ebp + KREL(win_h_data)], 160
    lea eax, [ebp + KREL(update_window_hitboxes)]
    call eax
    mov dword [ebp + KREL(drag_active_data)], 0
    mov dword [ebp + KREL(win_active_data)], 0 ; Окно стартует закрытым
    mov dword [ebp + KREL(menu_active_data)], 0
    lea eax, [ebp + KREL(gui_init)]
    call eax

    sti
    mov byte [ebp + KREL(need_redraw_data)], 1
    lea eax, [ebp + KREL(draw_gui)]
    call eax

.main_loop:
    lea eax, [ebp + KREL(handle_mouse_input)]
    call eax
    lea eax, [ebp + KREL(handle_keyboard_input)]
    call eax
    lea eax, [ebp + KREL(handle_window_drag)]
    call eax
    lea eax, [ebp + KREL(handle_menu)]
    call eax

    cli
    mov al, [ebp + KREL(need_redraw_data)]
    test al, al
    jnz .do_draw
    sti
    hlt
    jmp .main_loop

.do_draw:
    mov byte [ebp + KREL(need_redraw_data)], 0
    sti
    lea eax, [ebp + KREL(draw_gui)]
    call eax
    jmp .main_loop

; ======================================================================
;  ЭКСПОРТНАЯ ТАБЛИЦА
; ======================================================================
setup_export_table:
    pusha
    lea edi, [ebp + KREL(export_table_data)]

    lea eax, [ebp + KREL(flush_backbuffer)]
    stosd
    lea eax, [ebp + KREL(clear_backbuffer)]
    stosd
    lea eax, [ebp + KREL(draw_rect)]
    stosd
    lea eax, [ebp + KREL(draw_text)]
    stosd
    lea eax, [ebp + KREL(put_pixel)]
    stosd
    lea eax, [ebp + KREL(mouse_x_data)]
    stosd
    lea eax, [ebp + KREL(mouse_y_data)]
    stosd
    lea eax, [ebp + KREL(mouse_buttons_data)]
    stosd
    lea eax, [ebp + KREL(screen_width_data)]
    stosd
    lea eax, [ebp + KREL(screen_height_data)]
    stosd
    lea eax, [ebp + KREL(click_left_data)]
    stosd
    lea eax, [ebp + KREL(click_right_data)]
    stosd
    lea eax, [ebp + KREL(kb_buffer_data)]
    stosd
    lea eax, [ebp + KREL(kb_head_data)]
    stosd
    lea eax, [ebp + KREL(kb_tail_data)]
    stosd

    popa
    ret

; ======================================================================
;  ИНИЦИАЛИЗАЦИЯ МОДУЛЕЙ
; ======================================================================
init_stage4:
    pusha
    cmp word [STAGE4_ADDR + MOD_HEADER_SIG], SIG_STAGE4
    jne .no_module
    cmp word [STAGE4_ADDR + MOD_HEADER_VERSION], 1
    jb .no_module
    mov eax, [STAGE4_ADDR + MOD_HEADER_SIZE]
    cmp eax, MOD_HEADER_MIN_SIZE
    jb .no_module
    cmp eax, STAGE_MAX_SIZE
    ja .no_module
    mov eax, [STAGE4_ADDR + MOD_HEADER_ENTRY]
    cmp eax, MOD_HEADER_MIN_SIZE
    jb .no_module
    mov ecx, [STAGE4_ADDR + MOD_HEADER_SIZE]
    cmp eax, ecx
    ja .no_module
    cmp dword [STAGE4_ADDR + MOD_HEADER_RESERVED], 0
    jne .no_module

    add eax, STAGE4_ADDR
    mov ebx, eax
    lea eax, [ebp + KREL(export_table_data)]
    push ebp
    call ebx
    pop ebp

.no_module:
    popa
    ret

init_stage5:
    pusha
    cmp word [STAGE5_ADDR + MOD_HEADER_SIG], SIG_STAGE5
    jne .no_module
    cmp word [STAGE5_ADDR + MOD_HEADER_VERSION], 1
    jb .no_module
    mov eax, [STAGE5_ADDR + MOD_HEADER_SIZE]
    cmp eax, MOD_HEADER_MIN_SIZE
    jb .no_module
    cmp eax, STAGE_MAX_SIZE
    ja .no_module
    mov eax, [STAGE5_ADDR + MOD_HEADER_ENTRY]
    cmp eax, MOD_HEADER_MIN_SIZE
    jb .no_module
    mov ecx, [STAGE5_ADDR + MOD_HEADER_SIZE]
    cmp eax, ecx
    ja .no_module
    cmp dword [STAGE5_ADDR + MOD_HEADER_RESERVED], 0
    jne .no_module

    add eax, STAGE5_ADDR
    mov ebx, eax
    lea eax, [ebp + KREL(export_table_data)]
    push ebp
    call ebx
    pop ebp
.no_module:
    popa
    ret

init_stage6:
    pusha
    cmp word [STAGE6_ADDR + MOD_HEADER_SIG], SIG_STAGE6
    jne .no_module
    cmp word [STAGE6_ADDR + MOD_HEADER_VERSION], 1
    jb .no_module
    mov eax, [STAGE6_ADDR + MOD_HEADER_SIZE]
    cmp eax, MOD_HEADER_MIN_SIZE
    jb .no_module
    cmp eax, STAGE_MAX_SIZE
    ja .no_module
    mov eax, [STAGE6_ADDR + MOD_HEADER_ENTRY]
    cmp eax, MOD_HEADER_MIN_SIZE
    jb .no_module
    mov ecx, [STAGE6_ADDR + MOD_HEADER_SIZE]
    cmp eax, ecx
    ja .no_module
    cmp dword [STAGE6_ADDR + MOD_HEADER_RESERVED], 0
    jne .no_module

    add eax, STAGE6_ADDR
    mov ebx, eax
    lea eax, [ebp + KREL(export_table_data)]
    push ebp
    call ebx
    pop ebp
.no_module:
    popa
    ret

setup_irq12:
    pusha
    cmp word [STAGE4_ADDR + MOD_HEADER_SIG], SIG_STAGE4
    jne .no_irq12
    cmp word [STAGE4_ADDR + MOD_HEADER_VERSION], 1
    jb .no_irq12
    mov eax, [STAGE4_ADDR + MOD_HEADER_SIZE]
    cmp eax, MOD_HEADER_MIN_SIZE
    jb .no_irq12
    cmp eax, STAGE_MAX_SIZE
    ja .no_irq12
    mov eax, [STAGE4_ADDR + MOD_HEADER_IRQ12_ENTRY]
    cmp eax, MOD_HEADER_MIN_SIZE
    jb .no_irq12
    mov ecx, [STAGE4_ADDR + MOD_HEADER_SIZE]
    cmp eax, ecx
    ja .no_irq12
    cmp dword [STAGE4_ADDR + MOD_HEADER_RESERVED], 0
    jne .no_irq12

    add eax, STAGE4_ADDR
    lea edi, [ebp + KREL(idt_data) + 44*8]
    call fill_idt_entry
    jmp .done

.no_irq12:
    in al, 0xA1
    or al, 0x10
    out 0xA1, al

.done:
    popa
    ret

fill_idt_entry:
    push eax
    mov [edi], ax
    shr eax, 16
    mov [edi+6], ax
    pop eax
    mov word [edi+2], CODE_SEL
    mov word [edi+4], 0x8E00
    ret

; ======================================================================
;  ФУНКЦИИ ЯДРА
; ======================================================================

flush_backbuffer:
    pushfd
    cli
    pushad
    mov esi, [ebp + KREL(backbuffer_ptr_data)]
    mov edi, [ebp + KREL(vga_base_data)]
    mov ecx, 320 * 200 / 4
    rep movsd
    popad
    popfd
    ret

put_pixel:
    push eax
    push edx
    push ebx
    mov bl, al
    cmp ecx, 0
    jl .done
    cmp edx, 0
    jl .done
    cmp ecx, 320
    jae .done
    cmp edx, 200
    jae .done
    mov eax, edx
    imul eax, 320
    add eax, ecx
    add eax, [ebp + KREL(backbuffer_ptr_data)]
    mov [eax], bl
.done:
    pop ebx
    pop edx
    pop eax
    ret

handle_keyboard_input:
    pushfd
    cli
    pusha
    mov byte [ebp + KREL(temp_scancode_data)], 0
    mov eax, [ebp + KREL(kb_head_data)]
    cmp eax, [ebp + KREL(kb_tail_data)]
    je .empty
    movzx ecx, byte [ebp + KREL(kb_buffer_data) + eax]
    inc eax
    and eax, 0x3F
    mov [ebp + KREL(kb_head_data)], eax
    mov [ebp + KREL(temp_scancode_data)], cl
.empty:
    popa
    popfd
    cmp byte [ebp + KREL(temp_scancode_data)], 0x01
    jne .done
    call window_close
.done:
    ret

exception_handler_no_error:
    cli
.hang:
    hlt
    jmp .hang

exception_handler_error:
    add esp, 4
    cli
.hang2:
    hlt
    jmp .hang2

setup_idt:
    pusha
    lea edi, [ebp + KREL(idt_data)]
    mov ecx, 256
    lea eax, [ebp + KREL(exception_handler_no_error)]
.fill_loop:
    push eax
    mov [edi], ax
    shr eax, 16
    mov [edi+6], ax
    pop eax
    mov word [edi+2], CODE_SEL
    mov word [edi+4], 0x8E00
    add edi, 8
    loop .fill_loop

    lea edi, [ebp + KREL(idt_data) + 8*8]
    lea eax, [ebp + KREL(exception_handler_error)]
    call fill_idt_entry
    lea edi, [ebp + KREL(idt_data) + 10*8]
    lea eax, [ebp + KREL(exception_handler_error)]
    call fill_idt_entry
    lea edi, [ebp + KREL(idt_data) + 11*8]
    lea eax, [ebp + KREL(exception_handler_error)]
    call fill_idt_entry
    lea edi, [ebp + KREL(idt_data) + 12*8]
    lea eax, [ebp + KREL(exception_handler_error)]
    call fill_idt_entry
    lea edi, [ebp + KREL(idt_data) + 13*8]
    lea eax, [ebp + KREL(exception_handler_error)]
    call fill_idt_entry
    lea edi, [ebp + KREL(idt_data) + 14*8]
    lea eax, [ebp + KREL(exception_handler_error)]
    call fill_idt_entry
    lea edi, [ebp + KREL(idt_data) + 17*8]
    lea eax, [ebp + KREL(exception_handler_error)]
    call fill_idt_entry
    lea edi, [ebp + KREL(idt_data) + 21*8]
    lea eax, [ebp + KREL(exception_handler_error)]
    call fill_idt_entry

    lea edi, [ebp + KREL(idt_data) + 32*8]
    lea eax, [ebp + KREL(pit_handler)]
    call fill_idt_entry
    lea edi, [ebp + KREL(idt_data) + 33*8]
    lea eax, [ebp + KREL(keyboard_handler)]
    call fill_idt_entry
    call setup_irq12

    lea eax, [ebp + KREL(idt_data)]
    mov [ebp + KREL(idt_desc_data) + 2], eax
    lea eax, [ebp + KREL(idt_desc_data)]
    lidt [eax]
    popa
    ret

graphics_init:
    pusha
    mov dword [ebp + KREL(vga_base_data)], 0xA0000
    lea eax, [ebp + KREL(backbuffer_storage)]
    mov [ebp + KREL(backbuffer_ptr_data)], eax
    call clear_backbuffer
    popa
    ret

clear_backbuffer:
    pusha
    mov edi, [ebp + KREL(backbuffer_ptr_data)]
    mov ecx, 320 * 200
    mov al, 0x07
    rep stosb
    popa
    ret

draw_rect:
    pusha
    mov [ebp + KREL(rect_x_data)], ecx
    mov [ebp + KREL(rect_y_data)], edx
    mov [ebp + KREL(rect_w_data)], ebx
    mov [ebp + KREL(rect_h_data)], esi
    mov [ebp + KREL(rect_color_data)], al
    mov dword [ebp + KREL(rect_cur_y_data)], 0
.row:
    mov eax, [ebp + KREL(rect_cur_y_data)]
    cmp eax, [ebp + KREL(rect_h_data)]
    jge .end
    mov dword [ebp + KREL(rect_cur_x_data)], 0
.col:
    mov eax, [ebp + KREL(rect_cur_x_data)]
    cmp eax, [ebp + KREL(rect_w_data)]
    jge .next_row
    mov ecx, [ebp + KREL(rect_x_data)]
    add ecx, [ebp + KREL(rect_cur_x_data)]
    mov edx, [ebp + KREL(rect_y_data)]
    add edx, [ebp + KREL(rect_cur_y_data)]
    mov al, [ebp + KREL(rect_color_data)]
    call put_pixel
    inc dword [ebp + KREL(rect_cur_x_data)]
    jmp .col
.next_row:
    inc dword [ebp + KREL(rect_cur_y_data)]
    jmp .row
.end:
    popa
    ret

; ======================================================================
;  ФУНКЦИЯ: РИСОВАНИЕ КРУГА
; ======================================================================
draw_circle:
    pusha
    mov [ebp + KREL(circle_cx_data)], ecx
    mov [ebp + KREL(circle_cy_data)], edx
    mov [ebp + KREL(circle_r_data)], ebx
    mov [ebp + KREL(circle_color_data)], al

    ; y от (cy - r) до (cy + r)
    mov eax, edx
    sub eax, ebx
    mov [ebp + KREL(circle_cur_y_data)], eax

.cy_loop:
    mov eax, [ebp + KREL(circle_cur_y_data)]
    mov ecx, [ebp + KREL(circle_cy_data)]
    add ecx, [ebp + KREL(circle_r_data)]
    cmp eax, ecx
    jg .done

    ; dy = y - cy
    mov ecx, eax
    sub ecx, [ebp + KREL(circle_cy_data)]

    ; dx = sqrt(r^2 - dy^2)
    mov eax, [ebp + KREL(circle_r_data)]
    imul eax, eax
    mov ebx, ecx
    imul ebx, ebx
    sub eax, ebx
    cmp eax, 0
    jl .next_y

    ; целочисленный sqrt
    xor ebx, ebx
.sqrt_loop:
    mov edx, ebx
    imul edx, edx
    cmp edx, eax
    jg .sqrt_done
    inc ebx
    jmp .sqrt_loop
.sqrt_done:
    dec ebx

    ; x от (cx - dx) до (cx + dx)
    mov eax, [ebp + KREL(circle_cx_data)]
    sub eax, ebx
    mov [ebp + KREL(circle_cur_x_data)], eax
    mov ecx, [ebp + KREL(circle_cx_data)]
    add ecx, ebx
    mov [ebp + KREL(circle_x_end_data)], ecx

.cx_loop:
    mov eax, [ebp + KREL(circle_cur_x_data)]
    cmp eax, [ebp + KREL(circle_x_end_data)]
    jg .next_y
    mov ecx, eax
    mov edx, [ebp + KREL(circle_cur_y_data)]
    mov al, [ebp + KREL(circle_color_data)]
    call put_pixel
    inc dword [ebp + KREL(circle_cur_x_data)]
    jmp .cx_loop

.next_y:
    inc dword [ebp + KREL(circle_cur_y_data)]
    jmp .cy_loop
.done:
    popa
    ret

; ======================================================================
;  ШРИФТ И DRAW_CHAR (НЕ ТРОНУТО)
; ======================================================================
draw_char:
    pusha
    movzx eax, al
    shl eax, 3
    lea esi, [ebp + KREL(font8x8_data)]
    add esi, eax
    mov dword [ebp + KREL(rect_cur_y_data)], 0
.row_loop:
    cmp dword [ebp + KREL(rect_cur_y_data)], 8
    jge .char_done
    movzx ebx, byte [esi]
    inc esi
    mov dword [ebp + KREL(rect_cur_x_data)], 0
.bit_loop:
    cmp dword [ebp + KREL(rect_cur_x_data)], 8
    jge .next_row_char
    test ebx, 0x01
    jz .skip_pixel
    mov ecx, [ebp + KREL(text_x_data)]
    add ecx, [ebp + KREL(rect_cur_x_data)]
    mov edx, [ebp + KREL(text_y_data)]
    add edx, [ebp + KREL(rect_cur_y_data)]
    mov al, [ebp + KREL(text_color_data)]
    call put_pixel
.skip_pixel:
    shr ebx, 1
    inc dword [ebp + KREL(rect_cur_x_data)]
    jmp .bit_loop
.next_row_char:
    inc dword [ebp + KREL(rect_cur_y_data)]
    jmp .row_loop
.char_done:
    popa
    ret

draw_text:
    pusha
    mov [ebp + KREL(text_x_data)], ecx
    mov [ebp + KREL(text_y_data)], edx
    mov [ebp + KREL(text_color_data)], bl
    mov [ebp + KREL(text_str_data)], esi
.char_loop:
    lodsb
    test al, al
    jz .done_text
    call draw_char
    add dword [ebp + KREL(text_x_data)], 8
    jmp .char_loop
.done_text:
    popa
    ret

; ======================================================================
;  ОСТАЛЬНЫЕ ФУНКЦИИ ЯДРА
; ======================================================================
init_pit:
    pusha
    mov al, 0x34
    out 0x43, al
    mov ax, 11931
    out 0x40, al
    mov al, ah
    out 0x40, al
    popa
    ret

pit_handler:
    pusha
    inc dword [ebp + KREL(tick_count_data)]
    mov eax, [ebp + KREL(tick_count_data)]
    and eax, 0x07      ; <-- Изменено с 0x0F на 0x07 для более плавной анимации
    jnz .no_redraw
    mov byte [ebp + KREL(need_redraw_data)], 1
.no_redraw:
    mov al, 0x20
    out 0x20, al
    popa
    iretd

handle_mouse_input:
    pusha

    mov al, [ebp + KREL(mouse_buttons_data)]
    mov bl, [ebp + KREL(mouse_prev_buttons_data)]
    mov [ebp + KREL(mouse_prev_buttons_data)], al

    ; --- левая кнопка: down ---
    mov dl, al
    and dl, 1
    mov [ebp + KREL(left_down_data)], dl

    ; --- left_pressed = (buttons & ~prev) & 1 ---
    mov ah, bl
    not ah
    mov dl, al
    and dl, ah
    and dl, 1
    mov [ebp + KREL(left_pressed_data)], dl

    ; --- left_released = (~buttons & prev) & 1 ---
    mov ah, al
    not ah
    mov dl, bl
    and dl, ah
    and dl, 1
    mov [ebp + KREL(left_released_data)], dl

    ; --- правая кнопка ---
    mov dl, al
    shr dl, 1
    and dl, 1
    mov [ebp + KREL(right_down_data)], dl

    mov ah, bl
    not ah
    mov dl, al
    and dl, ah
    shr dl, 1
    and dl, 1
    mov [ebp + KREL(right_pressed_data)], dl

    mov ah, al
    not ah
    mov dl, bl
    and dl, ah
    shr dl, 1
    and dl, 1
    mov [ebp + KREL(right_released_data)], dl

    ; --- Обработка кликов по иконкам рабочего стола ---
    cmp byte [ebp + KREL(left_pressed_data)], 1
    jne .skip_desktop_click
    call handle_desktop_click
.skip_desktop_click:

    ; click_left = left_down
    mov dl, [ebp + KREL(left_down_data)]
    mov [ebp + KREL(click_left_data)], dl

    ; --- проверка изменений для перерисовки ---
    mov eax, [ebp + KREL(mouse_x_data)]
    cmp eax, [ebp + KREL(mouse_old_x_data)]
    jne .mouse_changed
    mov eax, [ebp + KREL(mouse_y_data)]
    cmp eax, [ebp + KREL(mouse_old_y_data)]
    je .check_buttons
.mouse_changed:
    mov byte [ebp + KREL(need_redraw_data)], 1
    mov eax, [ebp + KREL(mouse_x_data)]
    mov [ebp + KREL(mouse_old_x_data)], eax
    mov eax, [ebp + KREL(mouse_y_data)]
    mov [ebp + KREL(mouse_old_y_data)], eax

.check_buttons:
    mov al, [ebp + KREL(click_left_data)]
    cmp al, [ebp + KREL(last_click_left_data)]
    jne .changed
    mov al, [ebp + KREL(right_down_data)]
    cmp al, [ebp + KREL(last_click_right_data)]
    je .no_change
.changed:
    mov byte [ebp + KREL(need_redraw_data)], 1
    mov al, [ebp + KREL(click_left_data)]
    mov [ebp + KREL(last_click_left_data)], al
    mov al, [ebp + KREL(right_down_data)]
    mov [ebp + KREL(last_click_right_data)], al
.no_change:
    popa
    ret

; ======================================================================
;  ОБРАБОТЧИК КЛИКОВ ПО ИКОНКАМ
; ======================================================================
handle_desktop_click:
    pusha
    ; Проверяем иконку Terminal (10..90 по X, 10..18 по Y)
    mov eax, [ebp + KREL(mouse_x_data)]
    mov ebx, [ebp + KREL(mouse_y_data)]
    cmp eax, 10
    jl .done
    cmp eax, 90
    jg .done
    cmp ebx, 10
    jl .done
    cmp ebx, 18
    jg .done

    ; Клик по иконке Terminal!
    mov dword [ebp + KREL(win_active_data)], 1
    mov byte [ebp + KREL(need_redraw_data)], 1
.done:
    popa
    ret

update_window_hitboxes:
    pusha
    mov eax, [ebp + KREL(win_x_data)]
    add eax, [ebp + KREL(win_w_data)]
    sub eax, 14
    mov [ebp + KREL(close_x_data)], eax
    mov eax, [ebp + KREL(win_y_data)]
    add eax, 2
    mov [ebp + KREL(close_y_data)], eax
    popa
    ret

handle_window_drag:
    pusha
    cmp byte [ebp + KREL(win_active_data)], 0
    je .done
    cmp byte [ebp + KREL(click_left_data)], 0
    je .no_drag
    cmp dword [ebp + KREL(drag_active_data)], 1
    je .do_drag
    cmp dword [ebp + KREL(menu_active_data)], 1
    jne .not_menu
    mov eax, [ebp + KREL(menu_x_data)]
    mov ecx, [ebp + KREL(mouse_x_data)]
    mov edx, [ebp + KREL(mouse_y_data)]
    cmp ecx, eax
    jb .close_menu
    add eax, 220
    cmp ecx, eax
    jae .close_menu
    mov eax, [ebp + KREL(menu_y_data)]
    cmp edx, eax
    jb .close_menu
    add eax, 132
    cmp edx, eax
    jae .close_menu
    jmp .done
.close_menu:
    mov dword [ebp + KREL(menu_active_data)], 0
    mov byte [ebp + KREL(need_redraw_data)], 1
    jmp .done
.not_menu:
    mov eax, [ebp + KREL(close_x_data)]
    mov ecx, [ebp + KREL(mouse_x_data)]
    mov edx, [ebp + KREL(mouse_y_data)]
    cmp ecx, eax
    jb .check_title
    add eax, 12
    cmp ecx, eax
    jae .check_title
    mov eax, [ebp + KREL(close_y_data)]
    cmp edx, eax
    jb .check_title
    add eax, 12
    cmp edx, eax
    jae .check_title
    call window_close
    jmp .done
.check_title:
    mov eax, [ebp + KREL(win_x_data)]
    mov ecx, [ebp + KREL(mouse_x_data)]
    mov edx, [ebp + KREL(mouse_y_data)]
    cmp ecx, eax
    jb .done
    add eax, [ebp + KREL(win_w_data)]
    cmp ecx, eax
    jae .done
    mov eax, [ebp + KREL(win_y_data)]
    cmp edx, eax
    jb .done
    add eax, 16
    cmp edx, eax
    jae .done
    mov eax, ecx
    sub eax, [ebp + KREL(win_x_data)]
    mov [ebp + KREL(drag_offset_x_data)], eax
    mov eax, edx
    sub eax, [ebp + KREL(win_y_data)]
    mov [ebp + KREL(drag_offset_y_data)], eax
    mov dword [ebp + KREL(drag_active_data)], 1
    jmp .done
.no_drag:
    mov dword [ebp + KREL(drag_active_data)], 0
    jmp .done
.do_drag:
    mov eax, [ebp + KREL(mouse_x_data)]
    sub eax, [ebp + KREL(drag_offset_x_data)]
    mov [ebp + KREL(win_x_data)], eax
    mov eax, [ebp + KREL(mouse_y_data)]
    sub eax, [ebp + KREL(drag_offset_y_data)]
    mov [ebp + KREL(win_y_data)], eax
    cmp dword [ebp + KREL(win_x_data)], 0
    jge .bx
    mov dword [ebp + KREL(win_x_data)], 0
.bx:
    mov eax, [ebp + KREL(screen_width_data)]
    sub eax, [ebp + KREL(win_w_data)]
    cmp dword [ebp + KREL(win_x_data)], eax
    jle .by
    mov [ebp + KREL(win_x_data)], eax
.by:
    cmp dword [ebp + KREL(win_y_data)], 0
    jge .bok
    mov dword [ebp + KREL(win_y_data)], 0
.bok:
    mov eax, [ebp + KREL(screen_height_data)]
    sub eax, [ebp + KREL(win_h_data)]
    cmp dword [ebp + KREL(win_y_data)], eax
    jle .dd
    mov [ebp + KREL(win_y_data)], eax
.dd:
    call update_window_hitboxes
    mov byte [ebp + KREL(need_redraw_data)], 1
.done:
    popa
    ret

window_close:
    pusha
    mov dword [ebp + KREL(win_active_data)], 0
    mov dword [ebp + KREL(drag_active_data)], 0
    mov byte [ebp + KREL(need_redraw_data)], 1
    popa
    ret

handle_menu:
    pusha
    cmp byte [ebp + KREL(right_pressed_data)], 1
    jne .check_click
    cmp dword [ebp + KREL(win_active_data)], 0
    je .show
    mov eax, [ebp + KREL(win_x_data)]
    mov ecx, [ebp + KREL(mouse_x_data)]
    mov edx, [ebp + KREL(mouse_y_data)]
    cmp ecx, eax
    jb .show
    add eax, [ebp + KREL(win_w_data)]
    cmp ecx, eax
    jae .show
    mov eax, [ebp + KREL(win_y_data)]
    cmp edx, eax
    jb .show
    add eax, [ebp + KREL(win_h_data)]
    cmp edx, eax
    jae .show
    jmp .done
.show:
    mov eax, [ebp + KREL(mouse_x_data)]
    mov [ebp + KREL(menu_x_data)], eax
    mov eax, [ebp + KREL(mouse_y_data)]
    mov [ebp + KREL(menu_y_data)], eax
    cmp dword [ebp + KREL(menu_x_data)], 320-220
    jle .x_ok
    mov dword [ebp + KREL(menu_x_data)], 320-220
.x_ok:
    cmp dword [ebp + KREL(menu_y_data)], 200-132
    jle .y_ok
    mov dword [ebp + KREL(menu_y_data)], 200-132
.y_ok:
    mov dword [ebp + KREL(menu_active_data)], 1
    mov byte [ebp + KREL(need_redraw_data)], 1
    jmp .done
.check_click:
    cmp byte [ebp + KREL(left_pressed_data)], 1
    jne .done
    cmp dword [ebp + KREL(menu_active_data)], 1
    jne .done
    mov eax, [ebp + KREL(menu_x_data)]
    mov ecx, [ebp + KREL(mouse_x_data)]
    mov edx, [ebp + KREL(mouse_y_data)]
    cmp ecx, eax
    jb .close
    add eax, 220
    cmp ecx, eax
    jae .close
    mov eax, [ebp + KREL(menu_y_data)]
    cmp edx, eax
    jb .close
    add eax, 132
    cmp edx, eax
    jae .close
    call show_stub
    mov dword [ebp + KREL(menu_active_data)], 0
    mov byte [ebp + KREL(need_redraw_data)], 1
    jmp .done
.close:
    mov dword [ebp + KREL(menu_active_data)], 0
    mov byte [ebp + KREL(need_redraw_data)], 1
.done:
    popa
    ret

show_stub:
    pusha
    mov ecx, 50
    mov edx, 100
    mov ebx, 260
    mov esi, 40
    mov al, 0x08
    call draw_rect
    mov ecx, 55
    mov edx, 108
    lea esi, [ebp + KREL(msg_stub_data)]
    mov bl, 0x0F
    call draw_text
    mov byte [ebp + KREL(need_redraw_data)], 1
    call flush_backbuffer
    popa
    ret

gui_init:
    mov byte [ebp + KREL(need_redraw_data)], 1
    ret

; ======================================================================
;  DRAW_DESKTOP (СЦЕНА С АНИМАЦИЕЙ И Z-ПОРЯДКОМ)
; ======================================================================
draw_desktop:
    pusha

    ; --- 1. Небо ---
    mov ecx, 0
    mov edx, 0
    mov ebx, [ebp + KREL(screen_width_data)]
    mov esi, [ebp + KREL(screen_height_data)]
    sub esi, GRASS_HEIGHT
    sub esi, TASKBAR_HEIGHT
    mov al, SKY_COLOR
    call draw_rect

    ; --- 2. Трава и цветы ---
    call draw_grass
    call draw_flowers

    ; --- 3. Логика движения овечек ---
    call update_sheep_pos

    ; --- 4. Овечки ПЕРЕД деревом (X < 240) ---
    ; Овечка 1
    mov eax, [ebp + KREL(sheep1_pos)]
    cmp eax, 240
    jge .skip_s1
    mov ecx, eax
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 15
    call draw_sheep
.skip_s1:

    ; Овечка 2
    mov eax, [ebp + KREL(sheep2_pos)]
    cmp eax, 240
    jge .skip_s2
    mov ecx, eax
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 25
    call draw_sheep
.skip_s2:

    ; --- 5. Дерево ---
    call draw_tree

    ; --- 6. Овечки ЗА деревом (X >= 240) ---
    ; Овечка 1
    mov eax, [ebp + KREL(sheep1_pos)]
    cmp eax, 240
    jl .skip_s1b
    mov ecx, eax
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 15
    call draw_sheep
.skip_s1b:

    ; Овечка 2
    mov eax, [ebp + KREL(sheep2_pos)]
    cmp eax, 240
    jl .skip_s2b
    mov ecx, eax
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 25
    call draw_sheep
.skip_s2b:

    ; --- 7. Солнце ---
    mov ecx, SUN_X
    mov edx, SUN_Y
    mov ebx, SUN_R
    mov al, SUN_COLOR
    call draw_circle

    ; --- 8. Панель задач ---
    mov ecx, 0
    mov edx, [ebp + KREL(screen_height_data)]
    sub edx, TASKBAR_HEIGHT
    mov ebx, [ebp + KREL(screen_width_data)]
    mov esi, TASKBAR_HEIGHT
    mov al, TASKBAR_COLOR
    call draw_rect

    ; --- 9. Иконки ---
    call draw_desktop_icons

    popa
    ret

; ======================================================================
;  ЛОГИКА ДВИЖЕНИЯ ОВЕЧЕК
; ======================================================================
update_sheep_pos:
    pusha

    ; Получаем текущий тик
    mov eax, [ebp + KREL(tick_count_data)]

    ; Овечка 1 (ходит от 20 до 270)
    mov ecx, eax
    xor edx, edx
    mov ebx, 100
    div ebx
    cmp edx, 60
    jge .s1_eat
    ; Идёт
    mov eax, [ebp + KREL(sheep1_pos)]
    cmp eax, 270
    jge .s1_left
    inc dword [ebp + KREL(sheep1_pos)]
    jmp .s1_done
.s1_left:
    dec dword [ebp + KREL(sheep1_pos)]
    jmp .s1_done
.s1_eat:
.s1_done:

    ; Овечка 2 (ходит от 50 до 250)
    mov eax, [ebp + KREL(tick_count_data)]
    add eax, 50
    mov ecx, eax
    xor edx, edx
    mov ebx, 120
    div ebx
    cmp edx, 70
    jge .s2_eat
    ; Идёт
    mov eax, [ebp + KREL(sheep2_pos)]
    cmp eax, 250
    jge .s2_left
    inc dword [ebp + KREL(sheep2_pos)]
    jmp .s2_done
.s2_left:
    dec dword [ebp + KREL(sheep2_pos)]
    jmp .s2_done
.s2_eat:
.s2_done:

    ; Общий флаг для анимации головы (едим)
    mov eax, [ebp + KREL(tick_count_data)]
    mov ecx, eax
    xor edx, edx
    mov ebx, 80
    div ebx
    cmp edx, 40
    jge .set_eat
    mov dword [ebp + KREL(sheep_eat)], 0
    jmp .eat_set
.set_eat:
    mov dword [ebp + KREL(sheep_eat)], 1
.eat_set:

    popa
    ret

; ======================================================================
;  ФУНКЦИИ: ТРАВА, ЦВЕТЫ, ДЕРЕВО, ОВЕЧКИ, ИКОНКИ
; ======================================================================
draw_grass:
    pusha
    mov eax, [ebp + KREL(screen_height_data)]
    sub eax, GRASS_HEIGHT
    sub eax, TASKBAR_HEIGHT
    mov [ebp + KREL(grass_y_data)], eax

    ; base rect
    mov ecx, 0
    mov edx, eax
    mov ebx, [ebp + KREL(screen_width_data)]
    mov esi, GRASS_HEIGHT
    mov al, GRASS_COLOR
    call draw_rect

    ; hills
    mov edx, [ebp + KREL(grass_y_data)]
    mov ecx, 40
    mov ebx, 20
    mov al, GRASS_COLOR
    call draw_circle

    mov edx, [ebp + KREL(grass_y_data)]
    mov ecx, 120
    mov ebx, 15
    mov al, GRASS_COLOR
    call draw_circle

    mov edx, [ebp + KREL(grass_y_data)]
    mov ecx, 200
    mov ebx, 25
    mov al, GRASS_COLOR
    call draw_circle

    mov edx, [ebp + KREL(grass_y_data)]
    mov ecx, 280
    mov ebx, 18
    mov al, GRASS_COLOR
    call draw_circle

    popa
    ret

draw_flowers:
    pusha
    ; Chamomile 1
    mov ecx, 60
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 10
    mov ebx, 3
    mov al, 0x0F
    call draw_circle
    mov ecx, 60
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 10
    mov ebx, 1
    mov al, 0x0E
    call draw_circle

    ; Dandelion 1
    mov ecx, 150
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 20
    mov ebx, 2
    mov al, 0x0E
    call draw_circle

    ; Chamomile 2
    mov ecx, 230
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 5
    mov ebx, 3
    mov al, 0x0F
    call draw_circle
    mov ecx, 230
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 5
    mov ebx, 1
    mov al, 0x0E
    call draw_circle

    ; Dandelion 2
    mov ecx, 290
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 30
    mov ebx, 2
    mov al, 0x0E
    call draw_circle
    popa
    ret

; ======================================================================
;  ДЕРЕВО (РИСУНОК)
; ======================================================================
draw_tree:
    pusha
    ; Базовая координата ствола (X=260, Y=низ травы)
    mov ecx, 260
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, GRASS_HEIGHT
    sub edx, 10 ; чуть выше нижней границы травы

    ; --- Ствол (изгибы) ---
    ; Основной ствол
    mov ebx, 6
    mov esi, 30
    mov al, 0x06 ; коричневый
    call draw_rect

    ; Ветка влево
    mov ecx, 252
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 20
    mov ebx, 10
    mov esi, 4
    mov al, 0x06
    call draw_rect

    ; Ветка вправо
    mov ecx, 266
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 15
    mov ebx, 12
    mov esi, 4
    mov al, 0x06
    call draw_rect

    ; Верхняя ветка
    mov ecx, 258
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 10
    mov ebx, 4
    mov esi, 10
    mov al, 0x06
    call draw_rect

    ; --- Крона (несколько кругов) ---
    ; Центральный
    mov ecx, 263
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 10
    mov ebx, 18
    mov al, 0x02 ; темно-зеленый
    call draw_circle

    ; Левый
    mov ecx, 248
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 15
    mov ebx, 14
    mov al, 0x02
    call draw_circle

    ; Правый
    mov ecx, 278
    mov edx, [ebp + KREL(grass_y_data)]
    add edx, 15
    mov ebx, 14
    mov al, 0x02
    call draw_circle

    ; Верхний
    mov ecx, 263
    mov edx, [ebp + KREL(grass_y_data)]
    sub edx, 5
    mov ebx, 12
    mov al, 0x02
    call draw_circle

    popa
    ret

; ======================================================================
;  ОВЕЧКА (С АНИМАЦИЕЙ ШАГА И ЕДЫ)
; ======================================================================
draw_sheep:
    pusha
    mov [ebp + KREL(sheep_x_data)], ecx
    mov [ebp + KREL(sheep_y_data)], edx

    ; --- Тело (серое) ---
    mov ebx, 14 ; ширина
    mov esi, 8  ; высота
    mov al, 0x08 ; темно-серый
    call draw_rect

    ; --- Голова (белая) ---
    mov ecx, [ebp + KREL(sheep_x_data)]
    add ecx, 10
    mov edx, [ebp + KREL(sheep_y_data)]
    
    ; Если овечка ест — опускаем голову вниз
    mov eax, [ebp + KREL(sheep_eat)]
    test eax, eax
    jz .head_normal
    add edx, 3
.head_normal:
    sub edx, 4
    mov ebx, 6
    mov esi, 6
    mov al, 0x0F ; белый
    call draw_rect

    ; --- Глаз (черный) ---
    mov ecx, [ebp + KREL(sheep_x_data)]
    add ecx, 13
    mov edx, [ebp + KREL(sheep_y_data)]
    mov eax, [ebp + KREL(sheep_eat)]
    test eax, eax
    jz .eye_normal
    add edx, 3
.eye_normal:
    sub edx, 2
    mov ebx, 2
    mov esi, 2
    mov al, 0x00 ; черный
    call draw_rect

    ; --- Ножки (анимация шага) ---
    mov eax, [ebp + KREL(tick_count_data)]
    and eax, 8      ; 0 или 8 (меняется каждые 8 тиков)
    
    mov ebx, [ebp + KREL(sheep_eat)]
    test ebx, ebx
    jz .anim_legs
    mov eax, 0      ; если ест, ноги не двигаются
.anim_legs:
    
    ; Левая передняя
    mov ecx, [ebp + KREL(sheep_x_data)]
    add ecx, 2
    mov edx, [ebp + KREL(sheep_y_data)]
    add edx, 8
    mov ebx, 2
    mov esi, 6
    cmp eax, 0
    je .leg1
    add edx, 1
.leg1:
    mov al, 0x00
    call draw_rect

    ; Правая передняя
    mov ecx, [ebp + KREL(sheep_x_data)]
    add ecx, 10
    mov edx, [ebp + KREL(sheep_y_data)]
    add edx, 8
    mov ebx, 2
    mov esi, 6
    cmp eax, 0
    jne .leg2
    add edx, 1
.leg2:
    mov al, 0x00
    call draw_rect

    ; Левая задняя
    mov ecx, [ebp + KREL(sheep_x_data)]
    add ecx, 4
    mov edx, [ebp + KREL(sheep_y_data)]
    add edx, 8
    mov ebx, 2
    mov esi, 6
    cmp eax, 0
    jne .leg3
    add edx, 1
.leg3:
    mov al, 0x00
    call draw_rect

    ; Правая задняя
    mov ecx, [ebp + KREL(sheep_x_data)]
    add ecx, 8
    mov edx, [ebp + KREL(sheep_y_data)]
    add edx, 8
    mov ebx, 2
    mov esi, 6
    cmp eax, 0
    je .leg4
    add edx, 1
.leg4:
    mov al, 0x00
    call draw_rect

    popa
    ret

draw_desktop_icons:
    pusha
    ; Draw 8x8 white square
    mov ecx, 10
    mov edx, 10
    mov ebx, 8
    mov esi, 8
    mov al, 0x0F
    call draw_rect

    ; Draw "Terminal" text
    mov ecx, 22
    mov edx, 10
    mov bl, 0x0F
    lea esi, [ebp + KREL(msg_icon_terminal)]
    call draw_text
    popa
    ret

; ======================================================================
;  КУРСОР — белый крестик 8x8
; ======================================================================
draw_cursor:
    pusha

    ; Вертикальная палочка: 8 пикселей вниз от (mx, my)
    mov dword [ebp + KREL(rect_cur_y_data)], 0
.vloop:
    cmp dword [ebp + KREL(rect_cur_y_data)], 8
    jge .hdone
    mov ecx, [ebp + KREL(mouse_x_data)]
    mov edx, [ebp + KREL(mouse_y_data)]
    add edx, [ebp + KREL(rect_cur_y_data)]
    mov al, 0x0F
    call put_pixel
    inc dword [ebp + KREL(rect_cur_y_data)]
    jmp .vloop

.hdone:
    ; Горизонтальная палочка: 8 пикселей вправо от (mx, my)
    mov dword [ebp + KREL(rect_cur_x_data)], 0
.hloop:
    cmp dword [ebp + KREL(rect_cur_x_data)], 8
    jge .done
    mov ecx, [ebp + KREL(mouse_x_data)]
    add ecx, [ebp + KREL(rect_cur_x_data)]
    mov edx, [ebp + KREL(mouse_y_data)]
    mov al, 0x0F
    call put_pixel
    inc dword [ebp + KREL(rect_cur_x_data)]
    jmp .hloop

.done:
    popa
    ret

draw_window:
    pusha
    cmp dword [ebp + KREL(win_active_data)], 0
    je .end
    mov al, 0x0F
    mov ecx, [ebp + KREL(win_x_data)]
    sub ecx, 2
    mov edx, [ebp + KREL(win_y_data)]
    sub edx, 2
    mov ebx, [ebp + KREL(win_w_data)]
    add ebx, 4
    mov esi, [ebp + KREL(win_h_data)]
    add esi, 4
    call draw_rect
    mov al, 0x08
    mov ecx, [ebp + KREL(win_x_data)]
    mov edx, [ebp + KREL(win_y_data)]
    mov ebx, [ebp + KREL(win_w_data)]
    mov esi, [ebp + KREL(win_h_data)]
    call draw_rect
    mov al, 0x09
    mov ecx, [ebp + KREL(win_x_data)]
    mov edx, [ebp + KREL(win_y_data)]
    mov ebx, [ebp + KREL(win_w_data)]
    mov esi, 16
    call draw_rect
    mov ecx, [ebp + KREL(win_x_data)]
    add ecx, 5
    mov edx, [ebp + KREL(win_y_data)]
    add edx, 4
    lea esi, [ebp + KREL(msg_title_data)]
    mov bl, 0x0F
    call draw_text
    mov al, 0x0C
    mov ecx, [ebp + KREL(close_x_data)]
    mov edx, [ebp + KREL(close_y_data)]
    mov ebx, 12
    mov esi, 12
    call draw_rect
    mov ecx, [ebp + KREL(close_x_data)]
    add ecx, 3
    mov edx, [ebp + KREL(close_y_data)]
    add edx, 3
    lea esi, [ebp + KREL(msg_close_data)]
    mov bl, 0x0F
    call draw_text
.end:
    popa
    ret

draw_menu:
    pusha
    cmp dword [ebp + KREL(menu_active_data)], 0
    je .end
    mov al, 0x0F
    mov ecx, [ebp + KREL(menu_x_data)]
    sub ecx, 1
    mov edx, [ebp + KREL(menu_y_data)]
    sub edx, 1
    mov ebx, 222
    mov esi, 134
    call draw_rect
    mov al, 0x08
    mov ecx, [ebp + KREL(menu_x_data)]
    mov edx, [ebp + KREL(menu_y_data)]
    mov ebx, 220
    mov esi, 132
    call draw_rect
    mov ecx, [ebp + KREL(menu_x_data)]
    add ecx, 5
    mov edx, [ebp + KREL(menu_y_data)]
    add edx, 4
    lea esi, [ebp + KREL(menu_item1_data)]
    mov bl, 0x0F
    call draw_text
    add edx, 20
    lea esi, [ebp + KREL(menu_item2_data)]
    call draw_text
    add edx, 20
    lea esi, [ebp + KREL(menu_item3_data)]
    call draw_text
    add edx, 20
    lea esi, [ebp + KREL(menu_item4_data)]
    call draw_text
    add edx, 20
    lea esi, [ebp + KREL(menu_item5_data)]
    call draw_text
    add edx, 20
    lea esi, [ebp + KREL(menu_item6_data)]
    call draw_text
.end:
    popa
    ret

draw_gui:
    pusha
    call clear_backbuffer
    call draw_desktop
    call draw_window
    call draw_menu
    call draw_cursor
    call flush_backbuffer
    popa
    ret

keyboard_init:
    pusha
    mov dword [ebp + KREL(kb_head_data)], 0
    mov dword [ebp + KREL(kb_tail_data)], 0
    popa
    ret

keyboard_handler:
    pusha
    in al, 0x60
    mov dl, al
    test dl, 0x80
    jnz .done
    mov eax, [ebp + KREL(kb_tail_data)]
    mov ecx, eax
    inc ecx
    and ecx, 0x3F
    cmp ecx, [ebp + KREL(kb_head_data)]
    je .discard
    mov [ebp + KREL(kb_buffer_data) + eax], dl
    mov [ebp + KREL(kb_tail_data)], ecx
    jmp .done
.discard:
.done:
    mov al, 0x20
    out 0x20, al
    popa
    iretd

remap_pic:
    pusha
    mov al, 0x11
    out 0x20, al
    out 0xA0, al
    mov al, 0x20
    out 0x21, al
    mov al, 0x28
    out 0xA1, al
    mov al, 0x04
    out 0x21, al
    mov al, 0x02
    out 0xA1, al
    mov al, 0x01
    out 0x21, al
    out 0xA1, al
    mov al, 0xF8
    out 0x21, al
    mov al, 0xEF
    out 0xA1, al
    popa
    ret

; ======================================================================
;  ШРИФТ (полный 8x8, 2048 байт)
; ======================================================================
align 4
font8x8_data:
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x18,0x3C,0x3C,0x18,0x18,0x00,0x18,0x00
    db 0x36,0x36,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x36,0x36,0x7F,0x36,0x7F,0x36,0x36,0x00
    db 0x0C,0x3E,0x03,0x1E,0x30,0x1F,0x0C,0x00
    db 0x00,0x63,0x33,0x18,0x0C,0x66,0x63,0x00
    db 0x1C,0x36,0x1C,0x6E,0x3B,0x33,0x6E,0x00
    db 0x06,0x06,0x03,0x00,0x00,0x00,0x00,0x00
    db 0x18,0x0C,0x06,0x06,0x06,0x0C,0x18,0x00
    db 0x06,0x0C,0x18,0x18,0x18,0x0C,0x06,0x00
    db 0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00
    db 0x00,0x0C,0x0C,0x3F,0x0C,0x0C,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x06
    db 0x00,0x00,0x00,0x3F,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x0C,0x0C,0x00
    db 0x60,0x30,0x18,0x0C,0x06,0x03,0x01,0x00
    db 0x3E,0x63,0x73,0x7B,0x6F,0x67,0x3E,0x00
    db 0x0C,0x0E,0x0C,0x0C,0x0C,0x0C,0x3F,0x00
    db 0x1E,0x33,0x30,0x1C,0x06,0x33,0x3F,0x00
    db 0x1E,0x33,0x30,0x1C,0x30,0x33,0x1E,0x00
    db 0x38,0x3C,0x36,0x33,0x7F,0x30,0x78,0x00
    db 0x3F,0x03,0x1F,0x30,0x30,0x33,0x1E,0x00
    db 0x1C,0x06,0x03,0x1F,0x33,0x33,0x1E,0x00
    db 0x3F,0x33,0x30,0x18,0x0C,0x0C,0x0C,0x00
    db 0x1E,0x33,0x33,0x1E,0x33,0x33,0x1E,0x00
    db 0x1E,0x33,0x33,0x3E,0x30,0x18,0x0E,0x00
    db 0x00,0x0C,0x0C,0x00,0x00,0x0C,0x0C,0x00
    db 0x00,0x0C,0x0C,0x00,0x00,0x0C,0x0C,0x06
    db 0x18,0x0C,0x06,0x03,0x06,0x0C,0x18,0x00
    db 0x00,0x00,0x3F,0x00,0x00,0x3F,0x00,0x00
    db 0x06,0x0C,0x18,0x30,0x18,0x0C,0x06,0x00
    db 0x1E,0x33,0x30,0x18,0x0C,0x00,0x0C,0x00
    db 0x3E,0x63,0x7B,0x7B,0x7B,0x03,0x1E,0x00
    db 0x0C,0x1E,0x33,0x33,0x3F,0x33,0x33,0x00
    db 0x3F,0x66,0x66,0x3E,0x66,0x66,0x3F,0x00
    db 0x3C,0x66,0x03,0x03,0x03,0x66,0x3C,0x00
    db 0x1F,0x36,0x66,0x66,0x66,0x36,0x1F,0x00
    db 0x7F,0x46,0x16,0x1E,0x16,0x46,0x7F,0x00
    db 0x7F,0x46,0x16,0x1E,0x16,0x06,0x0F,0x00
    db 0x3C,0x66,0x03,0x03,0x73,0x66,0x7C,0x00
    db 0x33,0x33,0x33,0x3F,0x33,0x33,0x33,0x00
    db 0x1E,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E,0x00
    db 0x78,0x30,0x30,0x30,0x33,0x33,0x1E,0x00
    db 0x67,0x66,0x36,0x1E,0x36,0x66,0x67,0x00
    db 0x0F,0x06,0x06,0x06,0x46,0x66,0x7F,0x00
    db 0x63,0x77,0x7F,0x7F,0x6B,0x63,0x63,0x00
    db 0x63,0x67,0x6F,0x7B,0x73,0x63,0x63,0x00
    db 0x1C,0x36,0x63,0x63,0x63,0x36,0x1C,0x00
    db 0x3F,0x66,0x66,0x3E,0x06,0x06,0x0F,0x00
    db 0x1E,0x33,0x33,0x33,0x3B,0x1E,0x38,0x00
    db 0x3F,0x66,0x66,0x3E,0x36,0x66,0x67,0x00
    db 0x1E,0x33,0x07,0x0E,0x38,0x33,0x1E,0x00
    db 0x3F,0x2D,0x0C,0x0C,0x0C,0x0C,0x1E,0x00
    db 0x33,0x33,0x33,0x33,0x33,0x33,0x3F,0x00
    db 0x33,0x33,0x33,0x33,0x33,0x1E,0x0C,0x00
    db 0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00
    db 0x63,0x63,0x36,0x1C,0x1C,0x36,0x63,0x00
    db 0x33,0x33,0x33,0x1E,0x0C,0x0C,0x1E,0x00
    db 0x7F,0x63,0x31,0x18,0x4C,0x66,0x7F,0x00
    db 0x1E,0x06,0x06,0x06,0x06,0x06,0x1E,0x00
    db 0x03,0x06,0x0C,0x18,0x30,0x60,0x40,0x00
    db 0x1E,0x18,0x18,0x18,0x18,0x18,0x1E,0x00
    db 0x08,0x1C,0x36,0x63,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF
    db 0x0C,0x0C,0x18,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x1E,0x30,0x3E,0x33,0x6E,0x00
    db 0x07,0x06,0x06,0x3E,0x66,0x66,0x3B,0x00
    db 0x00,0x00,0x1E,0x33,0x03,0x33,0x1E,0x00
    db 0x38,0x30,0x30,0x3e,0x33,0x33,0x6E,0x00
    db 0x00,0x00,0x1E,0x33,0x3f,0x03,0x1E,0x00
    db 0x1C,0x36,0x06,0x0f,0x06,0x06,0x0F,0x00
    db 0x00,0x00,0x6E,0x33,0x33,0x3E,0x30,0x1F
    db 0x07,0x06,0x36,0x6E,0x66,0x66,0x67,0x00
    db 0x0C,0x00,0x0E,0x0C,0x0C,0x0C,0x1E,0x00
    db 0x30,0x00,0x30,0x30,0x30,0x33,0x33,0x1E
    db 0x07,0x06,0x66,0x36,0x1E,0x36,0x67,0x00
    db 0x0E,0x0C,0x0C,0x0C,0x0C,0x0C,0x1E,0x00
    db 0x00,0x00,0x33,0x7F,0x7F,0x6B,0x63,0x00
    db 0x00,0x00,0x1F,0x33,0x33,0x33,0x33,0x00
    db 0x00,0x00,0x1E,0x33,0x33,0x33,0x1E,0x00
    db 0x00,0x00,0x3B,0x66,0x66,0x3E,0x06,0x0F
    db 0x00,0x00,0x6E,0x33,0x33,0x3E,0x30,0x78
    db 0x00,0x00,0x3B,0x6E,0x66,0x06,0x0F,0x00
    db 0x00,0x00,0x3E,0x03,0x1E,0x30,0x1F,0x00
    db 0x08,0x0C,0x3E,0x0C,0x0C,0x2C,0x18,0x00
    db 0x00,0x00,0x33,0x33,0x33,0x33,0x6E,0x00
    db 0x00,0x00,0x33,0x33,0x33,0x1E,0x0C,0x00
    db 0x00,0x00,0x63,0x6B,0x7F,0x7F,0x36,0x00
    db 0x00,0x00,0x63,0x36,0x1C,0x36,0x63,0x00
    db 0x00,0x00,0x33,0x33,0x33,0x3E,0x30,0x1F
    db 0x00,0x00,0x3F,0x19,0x0C,0x26,0x3F,0x00
    db 0x38,0x0C,0x0C,0x07,0x0C,0x0C,0x38,0x00
    db 0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x00
    db 0x07,0x0C,0x0C,0x38,0x0C,0x0C,0x07,0x00
    db 0x6E,0x3B,0x00,0x00,0x00,0x00,0x00,0x00
    db 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00

; ======================================================================
;  ДАННЫЕ ЯДРА
; ======================================================================
align 8
idt_data:
    times 256*8 db 0

idt_desc_data:
    dw 256*8 - 1
    dd 0

vga_base_data dd 0xA0000
backbuffer_ptr_data dd 0
screen_width_data dd 320
screen_height_data dd 200
rect_x_data dd 0
rect_y_data dd 0
rect_w_data dd 0
rect_h_data dd 0
rect_cur_x_data dd 0
rect_cur_y_data dd 0
rect_color_data db 0

; --- ПЕРЕМЕННЫЕ ДЛЯ DRAW_CIRCLE, ГРАФИКИ, ОВЕЧЕК ---
circle_cx_data   dd 0
circle_cy_data   dd 0
circle_r_data    dd 0
circle_color_data db 0
circle_cur_y_data dd 0
circle_cur_x_data dd 0
circle_x_end_data dd 0
grass_y_data     dd 0
sheep_x_data     dd 0
sheep_y_data     dd 0
sheep1_pos       dd 50       ; Позиция овечки 1 по X
sheep2_pos       dd 180      ; Позиция овечки 2 по X
sheep_eat        dd 0        ; 0 = идет, 1 = ест (для анимации головы)
; -----------------------------------------

click_left_data db 0
click_right_data db 0
tick_count_data dd 0
need_redraw_data db 1
last_click_left_data db 0
last_click_right_data db 0
win_x_data dd 20
win_y_data dd 20
win_w_data dd 280
win_h_data dd 160
drag_active_data dd 0
drag_offset_x_data dd 0
drag_offset_y_data dd 0
win_active_data dd 1
close_x_data dd 0
close_y_data dd 0
menu_active_data dd 0
menu_x_data dd 0
menu_y_data dd 0
text_x_data dd 0
text_y_data dd 0
text_color_data db 0
text_str_data dd 0
kb_buffer_data times 64 db 0
kb_head_data dd 0
kb_tail_data dd 0
temp_scancode_data db 0

mouse_buttons_data db 0
mouse_x_data dd 160
mouse_y_data dd 100
mouse_prev_buttons_data db 0
left_down_data db 0
left_pressed_data db 0
left_released_data db 0
right_down_data db 0
right_pressed_data db 0
right_released_data db 0
mouse_old_x_data dd 160
mouse_old_y_data dd 100

msg_title_data db 'KindOS Terminal', 0
msg_close_data db 'X', 0
msg_stub_data db 'Please wait...', 0
msg_icon_terminal db 'Terminal', 0
menu_item1_data db 'Open', 0
menu_item2_data db 'Open as admin', 0
menu_item3_data db 'Delete', 0
menu_item4_data db 'Shortcut', 0
menu_item5_data db 'Copy', 0
menu_item6_data db 'Cut', 0

align 4
export_table_data:
    times 15 dd 0

align 16
backbuffer_storage times 320*200 db 0

kernel_end:
kernel_size equ kernel_end - kernel_entry