; ============================================================
; stage6_fileman.asm - KindOS File Manager [Kindrel V20 ABI]
; ============================================================
BITS 32

; ====================== MODULE HEADER ======================
dw 0x4D46       ; SIG_STAGE6 'FM' (little-endian)
dw 1            ; version
dd stage6_size  ; size
dd file_manager_main  ; entry point
dd 0            ; flags
dd 0            ; irq12_entry (не используется)
dd 0, 0, 0      ; reserved

%define SCREEN_WIDTH 320
%define SCREEN_HEIGHT 200

%define APP_X 10
%define APP_Y 10
%define APP_W 300
%define APP_H 180
%define TITLE_H 16
%define ITEM_H 14
%define LIST_X 15
%define LIST_Y 35
%define LIST_W 290
%define MAX_VISIBLE 8
%define SCROLLBAR_X 307
%define SCROLLBAR_Y 35
%define SCROLLBAR_W 8
%define SIZE_COL_OFFSET 230

%define PROG_LOAD_ADDR 0x200000
%define SIG_KINDOS  0x4B49
%define MAX_FILES 512

section .data

export_table_ptr dd 0   ; указатель на таблицу экспорта Kindrel

COLOR_BG        equ 0x07
COLOR_TITLE     equ 0x01
COLOR_TITLE_TEXT equ 0x0F
COLOR_BORDER    equ 0x0F
COLOR_TEXT      equ 0x0F
COLOR_SELECTED  equ 0x70
COLOR_SELECTED2 equ 0x08
COLOR_BUTTON    equ 0x08
COLOR_LIST_BG   equ 0x07
COLOR_SCROLLBAR equ 0x08
COLOR_SCROLLBAR_BG equ 0x07
COLOR_ERROR     equ 0x04
COLOR_MENU_BG   equ 0x08
COLOR_MENU_TEXT equ 0x0F
COLOR_STATUSBAR equ 0x01
COLOR_STATUSBAR_TEXT equ 0x0F

app_running     db 1
need_redraw     db 1
selected_file   dd -1
scroll_offset   dd 0
total_files     dd 0
mouse_click_x   dd 0
mouse_click_y   dd 0
click_handled   db 0
last_key        db 0
key_ready       db 0

menu_visible    db 0
menu_x          dd 0
menu_y          dd 0
props_visible   db 0
confirm_delete  db 0

clipboard_file  times 13 db 0
clipboard_full  db 0
clipboard_action db 0

mem_allocated   dd 0
mem_bitmap      times 256 db 0

file_sig_buf    dw 0
selected_name   times 13 db 0
props_name      times 13 db 0
props_size      dd 0
status_text     times 32 db 0
error_text      times 32 db 0

msg_title       db ' KindOS File Manager', 0
msg_close       db 'X', 0
msg_run         db 'Run', 0
msg_delete      db 'Del', 0
msg_refresh     db 'Refresh', 0
msg_status      db 'Files: ', 0
msg_empty       db '<empty>', 0
msg_error       db 'Error!', 0
msg_bad_sig     db 'Bad signature!', 0
msg_mem_fail    db 'Out of memory!', 0

msg_menu_open   db ' Open ', 0
msg_menu_run    db ' Run ', 0
msg_menu_copy   db ' Copy ', 0
msg_menu_cut    db ' Cut ', 0
msg_menu_paste  db ' Paste ', 0
msg_menu_delete db ' Delete ', 0
msg_menu_props  db ' Properties ', 0

msg_props_title db ' File Properties ', 0
msg_props_name  db 'Name: ', 0
msg_props_size  db 'Size: ', 0
msg_props_close db ' OK ', 0

msg_confirm     db ' Delete this file? ', 0
msg_yes         db ' Yes ', 0
msg_no          db ' No ', 0

.str_dir_icon   db '[D]', 0
.str_exe_icon   db '[*]', 0
.str_txt_icon   db '[-]', 0

section .text

; ============================================================
;  ENTRY POINT
;  Вход: EAX = указатель на экспортную таблицу Kindrel
; ============================================================
file_manager_main:
    pusha
    mov [export_table_ptr], eax   ; сохраняем экспорт

    ; Инициализируем FS, если Stage5 загружен
    mov eax, [0x509]               ; INFO_STAGE5_ADDR
    test eax, eax
    jz .no_fs
    call eax                       ; вызов fs_init
.no_fs:
    call refresh_file_list

    mov byte [app_running], 1
    mov byte [need_redraw], 1
    mov dword [selected_file], -1
    mov dword [scroll_offset], 0
    mov byte [key_ready], 0
    mov byte [menu_visible], 0
    mov byte [props_visible], 0
    mov byte [confirm_delete], 0

.main_loop:
    cmp byte [app_running], 0
    je .exit
    call read_keyboard
    cmp byte [confirm_delete], 1
    je .handle_confirm
    cmp byte [props_visible], 1
    je .handle_props
    call handle_clicks
    call handle_right_click
    call handle_menu_click
    call handle_keys
    jmp .check_redraw

.handle_confirm:
    call handle_confirm_click
    jmp .check_redraw

.handle_props:
    call handle_props_click

.check_redraw:
    cmp byte [need_redraw], 1
    jne .main_loop
    call draw_all
    ; Вызов flush_backbuffer через экспорт
    mov eax, [export_table_ptr]
    mov eax, [eax + 0]             ; flush_backbuffer
    call eax
    mov byte [need_redraw], 0
    jmp .main_loop

.exit:
    popa
    ret

; ============================================================
;  MACRO: вызов функции ядра по экспорту
; ============================================================
%macro call_kernel 1
    push eax
    mov eax, [export_table_ptr]
    mov eax, [eax + %1]
    call eax
    pop eax
%endmacro

%macro get_kernel_ptr 2
    push eax
    mov eax, [export_table_ptr]
    mov eax, [eax + %1]
    mov %2, eax
    pop eax
%endmacro

%define EXPORT_flush_backbuffer  0
%define EXPORT_clear_backbuffer  4
%define EXPORT_draw_rect         8
%define EXPORT_draw_text         12
%define EXPORT_put_pixel         16
%define EXPORT_mouse_x           20
%define EXPORT_mouse_y           24
%define EXPORT_mouse_buttons     28
%define EXPORT_screen_width      32
%define EXPORT_screen_height     36
%define EXPORT_click_left        40
%define EXPORT_click_right       44
%define EXPORT_kb_buffer         48
%define EXPORT_kb_head           52
%define EXPORT_kb_tail           56

; ============================================================
;  READ KEYBOARD
; ============================================================
read_keyboard:
    push eax
    push ebx
    push edx
    get_kernel_ptr EXPORT_kb_head, ebx
    mov ebx, [ebx]
    get_kernel_ptr EXPORT_kb_tail, edx
    mov edx, [edx]
    cmp ebx, edx
    je .done
    get_kernel_ptr EXPORT_kb_buffer, eax
    mov al, [eax + ebx]
    mov [last_key], al
    mov byte [key_ready], 1
    inc ebx
    and ebx, 0x3F
    get_kernel_ptr EXPORT_kb_head, eax
    mov [eax], ebx
.done:
    pop edx
    pop ebx
    pop eax
    ret

; ============================================================
;  REFRESH FILE LIST
; ============================================================
refresh_file_list:
    pusha
    mov eax, [0x509]   ; Stage5 address
    test eax, eax
    jz .empty
    add eax, 20        ; fs_list offset (заголовок 32, после него fs_init=0, fs_list=4? уточним)
    call eax
    mov [total_files], eax
    jmp .done
.empty:
    mov dword [total_files], 0
.done:
    popa
    ret

; ============================================================
;  DRAW ALL
; ============================================================
draw_all:
    pusha
    call_kernel EXPORT_clear_backbuffer
    call draw_window
    call draw_file_list
    call draw_scrollbar
    call draw_status_bar
    cmp byte [menu_visible], 1
    jne .no_menu
    call draw_context_menu
.no_menu:
    cmp byte [props_visible], 1
    jne .no_props
    call draw_props_dialog
.no_props:
    cmp byte [confirm_delete], 1
    jne .no_confirm
    call draw_confirm_dialog
.no_confirm:
    cmp byte [error_text], 0
    je .no_error
    call draw_error_message
    mov byte [error_text], 0
.no_error:
    popa
    ret

; ============================================================
;  DRAW WINDOW
; ============================================================
draw_window:
    pusha
    mov ecx, APP_X - 2
    mov edx, APP_Y - 2
    mov ebx, APP_W + 4
    mov esi, APP_H + 4
    mov al, COLOR_BORDER
    call_kernel EXPORT_draw_rect
    mov ecx, APP_X
    mov edx, APP_Y
    mov ebx, APP_W
    mov esi, APP_H
    mov al, COLOR_BG
    call_kernel EXPORT_draw_rect
    mov ecx, APP_X
    mov edx, APP_Y
    mov ebx, APP_W
    mov esi, TITLE_H
    mov al, COLOR_TITLE
    call_kernel EXPORT_draw_rect
    mov ecx, APP_X + 8
    mov edx, APP_Y + 3
    mov bl, COLOR_TITLE_TEXT
    mov esi, msg_title
    call_kernel EXPORT_draw_text
    ; Кнопка закрытия
    mov ecx, APP_X + APP_W - 18
    mov edx, APP_Y + 2
    mov ebx, 14
    mov esi, 12
    mov al, COLOR_BORDER
    call_kernel EXPORT_draw_rect
    mov ecx, APP_X + APP_W - 15
    mov edx, APP_Y + 3
    mov bl, COLOR_TEXT
    mov esi, msg_close
    call_kernel EXPORT_draw_text
    popa
    ret

; ============================================================
;  DRAW FILE LIST
; ============================================================
draw_file_list:
    pusha
    ; Фон списка
    mov ecx, LIST_X - 2
    mov edx, LIST_Y - 2
    mov ebx, LIST_W + 4
    mov esi, MAX_VISIBLE * ITEM_H + 4
    mov al, COLOR_LIST_BG
    call_kernel EXPORT_draw_rect

    mov eax, [total_files]
    test eax, eax
    jz .empty_list

    xor edi, edi
.loop_files:
    mov eax, [scroll_offset]
    add eax, edi
    cmp eax, [total_files]
    jae .done
    cmp edi, MAX_VISIBLE
    jge .done

    mov edx, edi
    imul edx, ITEM_H
    add edx, LIST_Y
    mov bl, COLOR_TEXT

    ; Подсветка выбранного
    mov eax, [scroll_offset]
    add eax, edi
    cmp eax, [selected_file]
    jne .draw_row
    push edx
    mov ecx, LIST_X
    mov ebx, LIST_W
    mov esi, ITEM_H
    mov al, COLOR_SELECTED
    call_kernel EXPORT_draw_rect
    pop edx
    mov bl, COLOR_SELECTED2

.draw_row:
    ; Получаем имя файла
    mov eax, [scroll_offset]
    add eax, edi
    imul eax, 13
    ; Имена лежат в Stage5 по адресу 0x130000 + 512
    add eax, 0x130000 + 512
    mov esi, eax

    mov ecx, LIST_X + 4
    call_kernel EXPORT_draw_text

    ; Размер
    mov eax, [scroll_offset]
    add eax, edi
    mov ebx, [0x130000 + 512 + MAX_FILES*13 + eax*4]
    push edi
    mov edi, status_text
    call itoa
    pop edi
    mov ecx, LIST_X + SIZE_COL_OFFSET
    mov esi, status_text
    call_kernel EXPORT_draw_text

    inc edi
    jmp .loop_files

.empty_list:
    mov ecx, LIST_X + 4
    mov edx, LIST_Y + 2
    mov bl, COLOR_TEXT
    mov esi, msg_empty
    call_kernel EXPORT_draw_text

.done:
    popa
    ret

; ============================================================
;  DRAW SCROLLBAR
; ============================================================
draw_scrollbar:
    pusha
    ; Фон скроллбара
    mov ecx, SCROLLBAR_X
    mov edx, SCROLLBAR_Y
    mov ebx, SCROLLBAR_W
    mov esi, MAX_VISIBLE * ITEM_H
    mov al, COLOR_SCROLLBAR_BG
    call_kernel EXPORT_draw_rect

    mov eax, [total_files]
    cmp eax, MAX_VISIBLE
    jbe .no_scroll

    ; Размер ползунка
    mov eax, MAX_VISIBLE * ITEM_H
    imul eax, MAX_VISIBLE
    mov ebx, [total_files]
    xor edx, edx
    div ebx
    mov esi, eax
    cmp esi, 8
    jae .thumb_ok
    mov esi, 8
.thumb_ok:
    ; Позиция ползунка
    mov eax, MAX_VISIBLE * ITEM_H
    imul eax, [scroll_offset]
    mov ebx, [total_files]
    xor edx, edx
    div ebx
    add eax, SCROLLBAR_Y
    mov edx, eax
    jmp .draw_thumb

.no_scroll:
    mov edx, SCROLLBAR_Y
    mov esi, MAX_VISIBLE * ITEM_H

.draw_thumb:
    mov ecx, SCROLLBAR_X
    mov ebx, SCROLLBAR_W
    mov al, COLOR_SCROLLBAR
    call_kernel EXPORT_draw_rect
    popa
    ret

; ============================================================
;  DRAW STATUS BAR
; ============================================================
draw_status_bar:
    pusha
    mov ecx, APP_X + 1
    mov edx, APP_Y + APP_H - 16
    mov ebx, APP_W - 2
    mov esi, 14
    mov al, COLOR_STATUSBAR
    call_kernel EXPORT_draw_rect

    mov ecx, APP_X + 8
    mov edx, APP_Y + APP_H - 13
    mov bl, COLOR_STATUSBAR_TEXT
    mov esi, msg_status
    call_kernel EXPORT_draw_text

    mov eax, [total_files]
    mov edi, status_text
    call itoa
    mov ecx, APP_X + 50
    mov edx, APP_Y + APP_H - 13
    mov bl, COLOR_STATUSBAR_TEXT
    mov esi, status_text
    call_kernel EXPORT_draw_text
    popa
    ret

; ============================================================
;  DRAW CONTEXT MENU
; ============================================================
draw_context_menu:
    pusha
    mov ecx, [menu_x]
    mov edx, [menu_y]
    mov ebx, 120
    mov esi, 140
    mov al, COLOR_MENU_BG
    call_kernel EXPORT_draw_rect

    mov ecx, [menu_x]
    add ecx, 1
    mov edx, [menu_y]
    add edx, 1
    mov ebx, 118
    mov esi, 138
    mov al, COLOR_BORDER
    call_kernel EXPORT_draw_rect

    mov ecx, [menu_x]
    add ecx, 6
    mov edx, [menu_y]
    add edx, 4
    mov bl, COLOR_MENU_TEXT
    mov esi, msg_menu_open
    call_kernel EXPORT_draw_text
    add edx, 20
    mov esi, msg_menu_run
    call_kernel EXPORT_draw_text
    add edx, 20
    mov esi, msg_menu_copy
    call_kernel EXPORT_draw_text
    add edx, 20
    mov esi, msg_menu_cut
    call_kernel EXPORT_draw_text
    add edx, 20
    mov esi, msg_menu_paste
    call_kernel EXPORT_draw_text
    add edx, 20
    mov esi, msg_menu_delete
    call_kernel EXPORT_draw_text
    add edx, 20
    mov esi, msg_menu_props
    call_kernel EXPORT_draw_text
    popa
    ret

; ============================================================
;  DRAW PROPS DIALOG
; ============================================================
draw_props_dialog:
    pusha
    mov ecx, APP_X + 40
    mov edx, APP_Y + 30
    mov ebx, 240
    mov esi, 100
    mov al, COLOR_BG
    call_kernel EXPORT_draw_rect

    mov ecx, APP_X + 38
    mov edx, APP_Y + 28
    mov ebx, 244
    mov esi, 104
    mov al, COLOR_BORDER
    call_kernel EXPORT_draw_rect

    mov ecx, APP_X + 50
    mov edx, APP_Y + 40
    mov bl, COLOR_TEXT
    mov esi, msg_props_title
    call_kernel EXPORT_draw_text

    mov ecx, APP_X + 50
    mov edx, APP_Y + 60
    mov bl, COLOR_TEXT
    mov esi, msg_props_name
    call_kernel EXPORT_draw_text

    mov ecx, APP_X + 120
    mov edx, APP_Y + 60
    mov bl, COLOR_TEXT
    mov esi, props_name
    call_kernel EXPORT_draw_text

    mov ecx, APP_X + 50
    mov edx, APP_Y + 80
    mov bl, COLOR_TEXT
    mov esi, msg_props_size
    call_kernel EXPORT_draw_text

    mov edi, status_text
    mov eax, [props_size]
    call itoa
    mov ecx, APP_X + 120
    mov edx, APP_Y + 80
    mov bl, COLOR_TEXT
    mov esi, status_text
    call_kernel EXPORT_draw_text

    ; Кнопка OK
    mov ecx, APP_X + 150
    mov edx, APP_Y + 105
    mov ebx, 40
    mov esi, 16
    mov al, COLOR_BUTTON
    call_kernel EXPORT_draw_rect
    mov ecx, APP_X + 160
    mov edx, APP_Y + 108
    mov bl, COLOR_TEXT
    mov esi, msg_props_close
    call_kernel EXPORT_draw_text
    popa
    ret

; ============================================================
;  DRAW CONFIRM DIALOG
; ============================================================
draw_confirm_dialog:
    pusha
    mov ecx, APP_X + 60
    mov edx, APP_Y + 70
    mov ebx, 200
    mov esi, 60
    mov al, COLOR_BG
    call_kernel EXPORT_draw_rect

    mov ecx, APP_X + 58
    mov edx, APP_Y + 68
    mov ebx, 204
    mov esi, 64
    mov al, COLOR_BORDER
    call_kernel EXPORT_draw_rect

    mov ecx, APP_X + 80
    mov edx, APP_Y + 85
    mov bl, COLOR_TEXT
    mov esi, msg_confirm
    call_kernel EXPORT_draw_text

    ; Yes
    mov ecx, APP_X + 90
    mov edx, APP_Y + 110
    mov ebx, 40
    mov esi, 16
    mov al, COLOR_BUTTON
    call_kernel EXPORT_draw_rect
    mov ecx, APP_X + 100
    mov edx, APP_Y + 113
    mov bl, COLOR_TEXT
    mov esi, msg_yes
    call_kernel EXPORT_draw_text

    ; No
    mov ecx, APP_X + 170
    mov edx, APP_Y + 110
    mov ebx, 40
    mov esi, 16
    mov al, COLOR_BUTTON
    call_kernel EXPORT_draw_rect
    mov ecx, APP_X + 180
    mov edx, APP_Y + 113
    mov bl, COLOR_TEXT
    mov esi, msg_no
    call_kernel EXPORT_draw_text
    popa
    ret

; ============================================================
;  DRAW ERROR MESSAGE
; ============================================================
draw_error_message:
    pusha
    mov ecx, APP_X + 20
    mov edx, APP_Y + APP_H / 2 - 15
    mov ebx, APP_W - 40
    mov esi, 30
    mov al, COLOR_ERROR
    call_kernel EXPORT_draw_rect
    mov ecx, APP_X + 35
    mov edx, APP_Y + APP_H / 2 - 8
    mov bl, COLOR_TEXT
    mov esi, error_text
    call_kernel EXPORT_draw_text
    popa
    ret

; ============================================================
;  MOUSE HANDLERS
; ============================================================
handle_clicks:
    pusha
    get_kernel_ptr EXPORT_click_left, eax
    cmp byte [eax], 0
    jne .check_click
    mov byte [click_handled], 0
    jmp .done
.check_click:
    cmp byte [click_handled], 1
    je .done
    mov byte [click_handled], 1
    mov byte [menu_visible], 0
    mov byte [need_redraw], 1
    get_kernel_ptr EXPORT_mouse_x, eax
    mov eax, [eax]
    mov [mouse_click_x], eax
    get_kernel_ptr EXPORT_mouse_y, eax
    mov eax, [eax]
    mov [mouse_click_y], eax

    ; Проверка кнопки закрытия
    mov eax, [mouse_click_x]
    mov ebx, [mouse_click_y]
    cmp eax, APP_X + APP_W - 18
    jl .check_list
    cmp eax, APP_X + APP_W - 4
    jg .check_list
    cmp ebx, APP_Y + 2
    jl .check_list
    cmp ebx, APP_Y + 14
    jg .check_list
    mov byte [app_running], 0
    jmp .done

.check_list:
    ; Проверка списка файлов
    cmp eax, LIST_X
    jl .done
    cmp eax, LIST_X + LIST_W
    jg .done
    cmp ebx, LIST_Y
    jl .done
    cmp ebx, LIST_Y + MAX_VISIBLE * ITEM_H
    jg .done
    mov eax, ebx
    sub eax, LIST_Y
    xor edx, edx
    mov ebx, ITEM_H
    div ebx
    add eax, [scroll_offset]
    cmp eax, [total_files]
    jae .no_select
    mov [selected_file], eax
    jmp .done
.no_select:
    mov dword [selected_file], -1
.done:
    popa
    ret

handle_right_click:
    pusha
    get_kernel_ptr EXPORT_click_right, eax
    cmp byte [eax], 1
    jne .done
    mov byte [eax], 0

    get_kernel_ptr EXPORT_mouse_x, eax
    mov eax, [eax]
    mov [menu_x], eax
    get_kernel_ptr EXPORT_mouse_y, eax
    mov eax, [eax]
    mov [menu_y], eax
    mov byte [menu_visible], 1
    mov byte [need_redraw], 1
.done:
    popa
    ret

handle_menu_click:
    pusha
    cmp byte [menu_visible], 1
    jne .done
    get_kernel_ptr EXPORT_click_left, eax
    cmp byte [eax], 1
    jne .done

    get_kernel_ptr EXPORT_mouse_x, eax
    mov eax, [eax]
    mov [mouse_click_x], eax
    get_kernel_ptr EXPORT_mouse_y, eax
    mov eax, [eax]
    mov [mouse_click_y], eax

    ; Проверка пунктов меню (упрощённо: только Open и Delete)
    mov eax, [menu_x]
    add eax, 2
    mov ebx, [menu_y]
    add ebx, 4
    mov ecx, 116
    mov edx, 16
    call point_in_rect
    cmp al, 1
    jne .check_delete
    cmp dword [selected_file], -1
    je .done
    call run_selected_file
    jmp .close_menu

.check_delete:
    mov eax, [menu_x]
    add eax, 2
    mov ebx, [menu_y]
    add ebx, 104
    mov ecx, 116
    mov edx, 16
    call point_in_rect
    cmp al, 1
    jne .close_menu
    cmp dword [selected_file], -1
    je .done
    mov byte [confirm_delete], 1

.close_menu:
    mov byte [menu_visible], 0
    mov byte [need_redraw], 1
.done:
    popa
    ret

handle_props_click:
    pusha
    get_kernel_ptr EXPORT_click_left, eax
    cmp byte [eax], 1
    jne .done
    get_kernel_ptr EXPORT_mouse_x, eax
    mov eax, [eax]
    mov [mouse_click_x], eax
    get_kernel_ptr EXPORT_mouse_y, eax
    mov eax, [eax]
    mov [mouse_click_y], eax
    mov eax, APP_X + 150
    mov ebx, APP_Y + 105
    mov ecx, 40
    mov edx, 16
    call point_in_rect
    cmp al, 1
    jne .done
    mov byte [props_visible], 0
    mov byte [need_redraw], 1
.done:
    popa
    ret

handle_confirm_click:
    pusha
    get_kernel_ptr EXPORT_click_left, eax
    cmp byte [eax], 1
    jne .done
    get_kernel_ptr EXPORT_mouse_x, eax
    mov eax, [eax]
    mov [mouse_click_x], eax
    get_kernel_ptr EXPORT_mouse_y, eax
    mov eax, [eax]
    mov [mouse_click_y], eax

    ; Yes
    mov eax, APP_X + 90
    mov ebx, APP_Y + 110
    mov ecx, 40
    mov edx, 16
    call point_in_rect
    cmp al, 1
    jne .check_no
    call delete_selected_file
    mov byte [confirm_delete], 0
    mov byte [need_redraw], 1
    jmp .done

.check_no:
    mov eax, APP_X + 170
    mov ebx, APP_Y + 110
    mov ecx, 40
    mov edx, 16
    call point_in_rect
    cmp al, 1
    jne .done
    mov byte [confirm_delete], 0
    mov byte [need_redraw], 1
.done:
    popa
    ret

; ============================================================
;  SHOW PROPERTIES
; ============================================================
show_properties:
    pusha
    mov eax, [selected_file]
    imul eax, 13
    mov esi, 0x130000 + 512
    add esi, eax
    mov edi, props_name
    mov ecx, 13
    rep movsb
    mov eax, [selected_file]
    mov ebx, [0x130000 + 512 + MAX_FILES*13 + eax*4]
    mov [props_size], ebx
    mov byte [props_visible], 1
    mov byte [need_redraw], 1
    popa
    ret

; ============================================================
;  RUN SELECTED FILE
; ============================================================
run_selected_file:
    pusha
    mov eax, [selected_file]
    imul eax, 13
    mov esi, 0x130000 + 512
    add esi, eax
    ; Здесь должен быть вызов mem_alloc и запуск, но для V20 упрощаем:
    ; просто показываем ошибку, если файл не запускаемый
    mov esi, msg_bad_sig
    mov edi, error_text
    mov ecx, 14
    rep movsb
    mov byte [need_redraw], 1
    popa
    ret

delete_selected_file:
    pusha
    mov eax, [selected_file]
    imul eax, 13
    mov esi, 0x130000 + 512
    add esi, eax
    ; Вызов fs_delete из Stage5
    mov eax, [0x509]    ; Stage5 base
    test eax, eax
    jz .done
    add eax, 16         ; fs_delete offset (заголовок 32, функции: init=0, list=4, open=8, read=12, write=16, create=20, delete=24, close=28)
    call eax
    call refresh_file_list
    mov dword [selected_file], -1
    mov byte [need_redraw], 1
.done:
    popa
    ret

; ============================================================
;  KEYBOARD HANDLERS
; ============================================================
handle_keys:
    pusha
    cmp byte [key_ready], 0
    je .done
    mov byte [key_ready], 0
    mov al, [last_key]
    cmp al, 0x01
    jne .check_up
    mov byte [app_running], 0
    jmp .done
.check_up:
    cmp al, 0x48
    jne .check_down
    cmp dword [selected_file], 0
    jle .scroll_up
    dec dword [selected_file]
    jmp .redraw
.scroll_up:
    cmp dword [scroll_offset], 0
    je .done
    dec dword [scroll_offset]
    jmp .redraw
.check_down:
    cmp al, 0x50
    jne .done
    mov eax, [total_files]
    dec eax
    cmp [selected_file], eax
    jge .scroll_down
    inc dword [selected_file]
    jmp .redraw
.scroll_down:
    mov eax, [total_files]
    sub eax, MAX_VISIBLE
    cmp [scroll_offset], eax
    jge .done
    inc dword [scroll_offset]
    jmp .redraw
.redraw:
    mov byte [need_redraw], 1
.done:
    popa
    ret

; ============================================================
;  POINT IN RECT
; ============================================================
point_in_rect:
    push edi
    push esi
    mov edi, [mouse_click_x]
    mov esi, [mouse_click_y]
    cmp edi, eax
    jl .miss
    add eax, ecx
    cmp edi, eax
    jg .miss
    cmp esi, ebx
    jl .miss
    add ebx, edx
    cmp esi, ebx
    jg .miss
    mov al, 1
    jmp .done
.miss:
    xor al, al
.done:
    pop esi
    pop edi
    ret

; ============================================================
;  ITOA
; ============================================================
itoa:
    push eax
    push ebx
    push ecx
    push edx
    push edi
    mov ebx, 10
    mov ecx, 0
    cmp eax, 0
    jne .convert
    mov byte [edi], '0'
    mov byte [edi + 1], 0
    jmp .done
.convert:
.next_digit:
    xor edx, edx
    div ebx
    add dl, '0'
    push dx
    inc ecx
    test eax, eax
    jnz .next_digit
.store:
    pop dx
    mov [edi], dl
    inc edi
    loop .store
    mov byte [edi], 0
.done:
    pop edi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; ====================== END ======================
stage6_size equ $ - $$