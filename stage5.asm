; ============================================
; stage5_disk.asm - KindOS Disk Subsystem
; Kindrel V20 ABI
; ============================================

BITS 32

; ====================== MODULE HEADER ======================
dw 0x4944       ; SIG_STAGE5 'DI' (little-endian)
dw 1            ; version
dd stage5_size  ; size
dd fs_init      ; entry point
dd 0            ; flags
dd 0            ; irq12_entry (не используется)
dd 0, 0, 0      ; reserved

ATA_PORT_DATA       equ 0x1F0
ATA_PORT_ERROR      equ 0x1F1
ATA_PORT_SECCOUNT   equ 0x1F2
ATA_PORT_LBA_LO     equ 0x1F3
ATA_PORT_LBA_MID    equ 0x1F4
ATA_PORT_LBA_HI     equ 0x1F5
ATA_PORT_DRIVE      equ 0x1F6
ATA_PORT_STATUS     equ 0x1F7
ATA_PORT_CMD        equ 0x1F7
ATA_CMD_READ        equ 0x20
ATA_CMD_WRITE       equ 0x30
ATA_STAT_BSY        equ 0x80
ATA_STAT_DRQ        equ 0x08
ATA_STAT_ERR        equ 0x01

SECTOR_SIZE         equ 512
MAX_FILES           equ 64
MAX_FILENAME        equ 13
MAX_HANDLES         equ 16

section .data
disk_type           db 0
disk_sectors        dd 0
disk_root_start     dd 0
disk_data_start     dd 0
disk_fat_start      dd 0
disk_sec_per_cluster db 0
disk_num_fats       db 0
disk_sectors_per_fat dw 0
disk_root_entries   dw 0
disk_bytes_per_sec  dw 512
disk_fat_type       db 0

align 4
disk_buffer         times 512 db 0
write_buffer        times 512 db 0
fat_buffer          times 512 db 0

file_count          dd 0
file_names          times MAX_FILES * MAX_FILENAME db 0
file_sizes          times MAX_FILES dd 0
file_clusters       times MAX_FILES dd 0

handles             times MAX_HANDLES dd 0
handle_pos          times MAX_HANDLES dd 0
handle_size         times MAX_HANDLES dd 0

prev_cluster        dd 0
current_dir_entry   dd 0
scan_index          dd 0
name_check_count    dd 0
saved_dir_entry     dd 0
fat_sector_to_write dd 0

section .text

; =============================================
;  FS_INIT - ИНИЦИАЛИЗАЦИЯ
; =============================================
fs_init:
    pusha
    mov al, [0x500]
    cmp al, 0x80
    je .detect_ata
    cmp al, 0x81
    je .detect_ata
    jmp .done

.detect_ata:
    mov byte [disk_type], 2
    mov eax, 0
    call ata_read_sector
    jc .done
    cmp word [disk_buffer + 0x1FE], 0xAA55
    jne .done
    mov eax, [disk_buffer + 0x20]
    mov [disk_sectors], eax
    mov ax, [disk_buffer + 0x0B]
    mov [disk_bytes_per_sec], ax
    mov al, [disk_buffer + 0x0D]
    mov [disk_sec_per_cluster], al
    mov ax, [disk_buffer + 0x0E]
    movzx eax, ax
    mov [disk_fat_start], eax
    mov al, [disk_buffer + 0x10]
    mov [disk_num_fats], al
    mov ax, [disk_buffer + 0x11]
    mov [disk_root_entries], ax
    mov ax, [disk_buffer + 0x16]
    mov [disk_sectors_per_fat], ax
    call detect_fat_type
    mov eax, [disk_fat_start]
    movzx ebx, byte [disk_num_fats]
    movzx ecx, word [disk_sectors_per_fat]
    imul ebx, ecx
    add eax, ebx
    mov [disk_root_start], eax
    movzx ebx, word [disk_root_entries]
    imul ebx, 32
    add ebx, SECTOR_SIZE - 1
    shr ebx, 9
    add eax, ebx
    mov [disk_data_start], eax
    call scan_root_directory
.done:
    popa
    ret

; =============================================
;  DETECT FAT TYPE
; =============================================
detect_fat_type:
    push eax
    push ebx
    mov eax, [disk_sectors]
    sub eax, [disk_fat_start]
    movzx ebx, byte [disk_num_fats]
    movzx ecx, word [disk_sectors_per_fat]
    imul ebx, ecx
    sub eax, ebx
    movzx ebx, word [disk_root_entries]
    imul ebx, 32
    shr ebx, 9
    sub eax, ebx
    movzx ebx, byte [disk_sec_per_cluster]
    div ebx
    cmp eax, 4085
    jbe .fat12
    cmp eax, 65525
    jbe .fat16
.fat32:
    mov byte [disk_fat_type], 32
    jmp .done
.fat16:
    mov byte [disk_fat_type], 16
    jmp .done
.fat12:
    mov byte [disk_fat_type], 12
.done:
    pop ebx
    pop eax
    ret

; =============================================
;  ATA READ SECTOR
; =============================================
ata_read_sector:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, eax
.wait_ready:
    mov dx, ATA_PORT_STATUS
    in al, dx
    test al, ATA_STAT_BSY
    jnz .wait_ready
    mov dx, ATA_PORT_SECCOUNT
    mov al, 1
    out dx, al
    mov dx, ATA_PORT_LBA_LO
    mov al, bl
    out dx, al
    mov dx, ATA_PORT_LBA_MID
    mov al, bh
    out dx, al
    shr ebx, 16
    mov dx, ATA_PORT_LBA_HI
    mov al, bl
    out dx, al
    mov dx, ATA_PORT_DRIVE
    mov al, 0xE0
    or al, bh
    out dx, al
    mov dx, ATA_PORT_CMD
    mov al, ATA_CMD_READ
    out dx, al
.wait_drq:
    mov dx, ATA_PORT_STATUS
    in al, dx
    test al, ATA_STAT_BSY
    jnz .wait_drq
    test al, ATA_STAT_DRQ
    jz .check_error
    test al, ATA_STAT_ERR
    jnz .error
    mov edi, disk_buffer
    mov ecx, 256
    mov dx, ATA_PORT_DATA
    rep insw
    clc
    jmp .done
.check_error:
    test al, ATA_STAT_ERR
    jz .wait_drq
.error:
    stc
.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; =============================================
;  ATA WRITE SECTOR
; =============================================
ata_write_sector:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, eax
.wait_ready:
    mov dx, ATA_PORT_STATUS
    in al, dx
    test al, ATA_STAT_BSY
    jnz .wait_ready
    mov dx, ATA_PORT_SECCOUNT
    mov al, 1
    out dx, al
    mov dx, ATA_PORT_LBA_LO
    mov al, bl
    out dx, al
    mov dx, ATA_PORT_LBA_MID
    mov al, bh
    out dx, al
    shr ebx, 16
    mov dx, ATA_PORT_LBA_HI
    mov al, bl
    out dx, al
    mov dx, ATA_PORT_DRIVE
    mov al, 0xE0
    or al, bh
    out dx, al
    mov dx, ATA_PORT_CMD
    mov al, ATA_CMD_WRITE
    out dx, al
.wait_drq:
    mov dx, ATA_PORT_STATUS
    in al, dx
    test al, ATA_STAT_BSY
    jnz .wait_drq
    test al, ATA_STAT_DRQ
    jz .check_error
    test al, ATA_STAT_ERR
    jnz .error
    mov esi, write_buffer
    mov ecx, 256
    mov dx, ATA_PORT_DATA
    rep outsw
.wait_flush:
    mov dx, ATA_PORT_STATUS
    in al, dx
    test al, ATA_STAT_BSY
    jnz .wait_flush
    clc
    jmp .done
.check_error:
    test al, ATA_STAT_ERR
    jz .wait_drq
.error:
    stc
.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; =============================================
;  READ FAT SECTOR
; =============================================
ata_read_sector_fat:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, eax
.wait_ready:
    mov dx, ATA_PORT_STATUS
    in al, dx
    test al, ATA_STAT_BSY
    jnz .wait_ready
    mov dx, ATA_PORT_SECCOUNT
    mov al, 1
    out dx, al
    mov dx, ATA_PORT_LBA_LO
    mov al, bl
    out dx, al
    mov dx, ATA_PORT_LBA_MID
    mov al, bh
    out dx, al
    shr ebx, 16
    mov dx, ATA_PORT_LBA_HI
    mov al, bl
    out dx, al
    mov dx, ATA_PORT_DRIVE
    mov al, 0xE0
    or al, bh
    out dx, al
    mov dx, ATA_PORT_CMD
    mov al, ATA_CMD_READ
    out dx, al
.wait_drq:
    mov dx, ATA_PORT_STATUS
    in al, dx
    test al, ATA_STAT_BSY
    jnz .wait_drq
    test al, ATA_STAT_DRQ
    jz .check_error
    test al, ATA_STAT_ERR
    jnz .error
    mov edi, fat_buffer
    mov ecx, 256
    mov dx, ATA_PORT_DATA
    rep insw
    clc
    jmp .done
.check_error:
    test al, ATA_STAT_ERR
    jz .wait_drq
.error:
    stc
.done:
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; =============================================
;  DISK READ/WRITE
; =============================================
disk_read_sector:
    push eax
    cmp byte [disk_type], 2
    jne .done
    call ata_read_sector
.done:
    pop eax
    ret

disk_write_sector:
    push eax
    cmp byte [disk_type], 2
    jne .done
    call ata_write_sector
.done:
    pop eax
    ret

disk_read_sector_fat:
    push eax
    cmp byte [disk_type], 2
    jne .done
    call ata_read_sector_fat
.done:
    pop eax
    ret

; =============================================
;  SCAN ROOT DIRECTORY
; =============================================
scan_root_directory:
    pusha
    mov dword [file_count], 0
    mov esi, file_names
    mov edi, file_sizes
    mov ebx, file_clusters
    mov ecx, [disk_root_entries]
    mov dword [scan_index], 0
.scan_loop:
    cmp dword [scan_index], ecx
    jae .done_scan
    mov eax, [scan_index]
    shr eax, 4
    add eax, [disk_root_start]
    call disk_read_sector
    mov eax, [scan_index]
    and eax, 0x0F
    imul eax, 32
    add eax, disk_buffer
    mov [current_dir_entry], eax
    mov dl, [eax]
    cmp dl, 0x00
    je .done_scan
    cmp dl, 0xE5
    je .next_entry
    mov dl, [eax + 11]
    test dl, 0x08
    jnz .next_entry
    test dl, 0x0F
    jnz .next_entry
    push esi
    mov ecx, 8
    mov eax, [current_dir_entry]
.copy_name:
    mov dl, [eax]
    cmp dl, ' '
    je .pad_name
    mov [esi], dl
    inc esi
    inc eax
    loop .copy_name
    jmp .add_ext
.pad_name:
    inc eax
    loop .pad_name
.add_ext:
    mov byte [esi], '.'
    inc esi
    mov ecx, 3
    mov eax, [current_dir_entry]
    add eax, 8
.copy_ext:
    mov dl, [eax]
    cmp dl, ' '
    je .pad_ext
    mov [esi], dl
    inc esi
    inc eax
    loop .copy_ext
    jmp .finish_name
.pad_ext:
    inc eax
    loop .pad_ext
.finish_name:
    mov byte [esi], 0
    mov eax, [current_dir_entry]
    add eax, 28
    mov edx, [eax]
    mov [edi], edx
    add edi, 4
    mov eax, [current_dir_entry]
    add eax, 26
    mov dx, [eax]
    movzx edx, dx
    mov [ebx], edx
    add ebx, 4
    inc dword [file_count]
    pop esi
    add esi, MAX_FILENAME
.next_entry:
    inc dword [scan_index]
    jmp .scan_loop
.done_scan:
    popa
    ret

; =============================================
;  FS_LIST
; =============================================
fs_list:
    mov eax, [file_count]
    ret

; =============================================
;  FS_OPEN
; =============================================
fs_open:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov ecx, [file_count]
    test ecx, ecx
    jz .not_found
    mov edi, file_names
    xor ebx, ebx
.search:
    push ecx
    push esi
    push edi
    mov ecx, MAX_FILENAME
    repe cmpsb
    jne .try_next
    mov edi, handles
    mov ecx, MAX_HANDLES
.find_handle:
    cmp dword [edi], 0
    je .found_handle
    add edi, 4
    loop .find_handle
    jmp .not_found
.found_handle:
    mov eax, [file_clusters + ebx*4]
    mov [edi], eax
    mov eax, edi
    sub eax, handles
    mov [handle_pos + eax], dword 0
    mov edx, [file_sizes + ebx*4]
    mov [handle_size + eax], edx
    shr eax, 2
    inc eax
    jmp .done
.try_next:
    pop edi
    pop esi
    pop ecx
    add edi, MAX_FILENAME
    inc ebx
    loop .search
.not_found:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; =============================================
;  FS_READ
; =============================================
fs_read:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, esp
    cmp eax, MAX_HANDLES
    ja .error
    dec eax
    mov ebx, [handles + eax*4]
    test ebx, ebx
    jz .error
    mov edx, [handle_pos + eax*4]
    mov esi, [handle_size + eax*4]
    add edx, ecx
    cmp edx, esi
    jbe .size_ok
    sub edx, esi
    sub ecx, edx
    mov edx, esi
.size_ok:
    sub edx, ecx
    mov [handle_pos + eax*4], edx
    push ecx
.read_loop:
    cmp dword [esp], 0
    jz .read_done
    mov eax, ebx
    call cluster_to_sector
    call disk_read_sector
    mov esi, disk_buffer
    mov ecx, [esp]
    cmp ecx, 512
    jbe .copy_ok
    mov ecx, 512
.copy_ok:
    rep movsb
    sub [esp], ecx
    call get_next_cluster
    jc .read_done
    jmp .read_loop
.read_done:
    pop ecx
    mov eax, ecx
.done:
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
.error:
    xor eax, eax
    jmp .done

; =============================================
;  FS_WRITE
; =============================================
fs_write:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push edx
    push esi
    push edi
    cmp eax, MAX_HANDLES
    ja .error
    dec eax
    mov ebx, [handles + eax*4]
    test ebx, ebx
    jz .error
    push ecx
    push eax
    mov dword [prev_cluster], 0
.write_loop:
    cmp dword [esp + 4], 0
    jz .write_done
    cmp byte [disk_fat_type], 12
    jne .check_fat16_end
    cmp ebx, 0xFF8
    jae .need_extend
    jmp .have_cluster
.check_fat16_end:
    cmp byte [disk_fat_type], 32
    jne .check_fat16_end2
    cmp ebx, 0x0FFFFFF8
    jae .need_extend
    jmp .have_cluster
.check_fat16_end2:
    cmp ebx, 0xFFF8
    jae .need_extend
    jmp .have_cluster
.need_extend:
    mov [prev_cluster], ebx
    call alloc_cluster
    test eax, eax
    jz .write_done
    cmp dword [prev_cluster], 0
    je .first_extend
    push eax
    mov ebx, [prev_cluster]
    mov eax, [prev_cluster]
    call write_fat_entry
    pop eax
.first_extend:
    mov ebx, eax
    mov [prev_cluster], ebx
.have_cluster:
    mov eax, ebx
    call cluster_to_sector
    push edi
    mov edi, write_buffer
    mov ecx, [esp + 12]
    cmp ecx, 512
    jbe .copy_size_ok
    mov ecx, 512
.copy_size_ok:
    rep movsb
    pop edi
    add esi, ecx
    sub [esp + 4], ecx
    call disk_write_sector
    mov [prev_cluster], ebx
    call get_next_cluster
    jc .write_done
    jmp .write_loop
.write_done:
    pop eax
    pop ecx
    sub ecx, [esp]
    mov eax, ecx
    mov ebx, [handles + eax*4]
    add [handle_size + eax*4], ecx
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop ebp
    ret
.error:
    xor eax, eax
    jmp .done

; =============================================
;  GET_NEXT_CLUSTER
; =============================================
get_next_cluster:
    push eax
    push ecx
    push edx
    cmp byte [disk_fat_type], 12
    je .fat12
    cmp byte [disk_fat_type], 32
    je .fat32
.fat16:
    mov eax, ebx
    shl eax, 1
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    pop edx
    add edx, fat_buffer
    movzx ebx, word [edx]
    cmp ebx, 0xFFF8
    jae .end_chain
    clc
    jmp .done
.fat12:
    push ebx
    mov eax, ebx
    add eax, ebx
    shr eax, 1
    add eax, ebx
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    pop edx
    add edx, fat_buffer
    movzx ebx, word [edx]
    pop eax
    test eax, 1
    jz .fat12_even
    shr ebx, 4
.fat12_even:
    and ebx, 0xFFF
    cmp ebx, 0xFF8
    jae .end_chain
    clc
    jmp .done
.fat32:
    mov eax, ebx
    shl eax, 2
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    pop edx
    add edx, fat_buffer
    mov ebx, [edx]
    and ebx, 0x0FFFFFFF
    cmp ebx, 0x0FFFFFF8
    jae .end_chain
    clc
    jmp .done
.end_chain:
    stc
.done:
    pop edx
    pop ecx
    pop eax
    ret

; =============================================
;  WRITE_FAT_ENTRY
; =============================================
write_fat_entry:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    cmp byte [disk_fat_type], 12
    je .fat12
    cmp byte [disk_fat_type], 32
    je .fat32
.fat16:
    push eax
    mov eax, ebx
    shl eax, 1
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    mov [fat_sector_to_write], eax
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    mov esi, fat_buffer
    mov edi, write_buffer
    mov ecx, 512
    rep movsb
    pop edx
    pop eax
    add edx, write_buffer
    mov [edx], ax
    mov eax, [fat_sector_to_write]
    call disk_write_sector
    cmp byte [disk_num_fats], 2
    jne .done
    mov eax, [fat_sector_to_write]
    add eax, [disk_sectors_per_fat]
    call disk_write_sector
    jmp .done
.fat12:
    push eax
    push ebx
    mov eax, ebx
    add eax, ebx
    shr eax, 1
    add eax, ebx
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    mov [fat_sector_to_write], eax
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    mov esi, fat_buffer
    mov edi, write_buffer
    mov ecx, 512
    rep movsb
    pop edx
    pop ebx
    pop eax
    add edx, write_buffer
    mov cx, [edx]
    test ebx, 1
    jz .fat12_even
    and cx, 0x000F
    shl eax, 4
    or cx, ax
    jmp .fat12_save
.fat12_even:
    and cx, 0xF000
    and eax, 0x0FFF
    or cx, ax
.fat12_save:
    mov [edx], cx
    mov eax, [fat_sector_to_write]
    call disk_write_sector
    cmp byte [disk_num_fats], 2
    jne .done
    mov eax, [fat_sector_to_write]
    add eax, [disk_sectors_per_fat]
    call disk_write_sector
    jmp .done
.fat32:
    push eax
    mov eax, ebx
    shl eax, 2
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    mov [fat_sector_to_write], eax
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    mov esi, fat_buffer
    mov edi, write_buffer
    mov ecx, 512
    rep movsb
    pop edx
    pop eax
    add edx, write_buffer
    and dword [edx], 0xF0000000
    or [edx], eax
    mov eax, [fat_sector_to_write]
    call disk_write_sector
    cmp byte [disk_num_fats], 2
    jne .done
    mov eax, [fat_sector_to_write]
    add eax, [disk_sectors_per_fat]
    call disk_write_sector
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; =============================================
;  ALLOC_CLUSTER
; =============================================
alloc_cluster:
    push ebx
    push ecx
    push edx
    mov ebx, 2
.search_loop:
    call get_next_cluster_raw
    cmp eax, 0
    je .found
    inc ebx
    mov eax, [disk_sectors]
    sub eax, [disk_data_start]
    movzx ecx, byte [disk_sec_per_cluster]
    xor edx, edx
    div ecx
    add eax, 2
    cmp ebx, eax
    jb .search_loop
    xor eax, eax
    jmp .done
.found:
    push ebx
    mov eax, ebx
    call mark_cluster_end
    pop eax
.done:
    pop edx
    pop ecx
    pop ebx
    ret

; =============================================
;  GET_NEXT_CLUSTER_RAW
; =============================================
get_next_cluster_raw:
    push ebx
    push ecx
    push edx
    cmp byte [disk_fat_type], 12
    je .fat12
    cmp byte [disk_fat_type], 32
    je .fat32
.fat16:
    mov eax, ebx
    shl eax, 1
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    pop edx
    add edx, fat_buffer
    movzx eax, word [edx]
    jmp .done
.fat12:
    push ebx
    mov eax, ebx
    add eax, ebx
    shr eax, 1
    add eax, ebx
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    pop edx
    add edx, fat_buffer
    movzx eax, word [edx]
    pop ebx
    test ebx, 1
    jz .fat12_even
    shr eax, 4
.fat12_even:
    and eax, 0xFFF
    jmp .done
.fat32:
    mov eax, ebx
    shl eax, 2
    xor edx, edx
    movzx ecx, word [disk_bytes_per_sec]
    div ecx
    add eax, [disk_fat_start]
    push edx
    push eax
    call disk_read_sector_fat
    pop eax
    pop edx
    add edx, fat_buffer
    mov eax, [edx]
    and eax, 0x0FFFFFFF
.done:
    pop edx
    pop ecx
    pop ebx
    ret

; =============================================
;  MARK_CLUSTER_END
; =============================================
mark_cluster_end:
    push eax
    push ebx
    push ecx
    push edx
    mov ebx, eax
    cmp byte [disk_fat_type], 12
    je .fat12
    cmp byte [disk_fat_type], 32
    je .fat32
.fat16:
    mov eax, 0xFFFF
    jmp .write
.fat12:
    mov eax, 0xFFF
    jmp .write
.fat32:
    mov eax, 0x0FFFFFFF
.write:
    call write_fat_entry
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; =============================================
;  CLUSTER_TO_SECTOR
; =============================================
cluster_to_sector:
    sub eax, 2
    movzx edx, byte [disk_sec_per_cluster]
    mul edx
    add eax, [disk_data_start]
    ret

; =============================================
;  FS_CREATE
; =============================================
fs_create:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov ecx, [disk_root_entries]
    mov dword [scan_index], 0
.find_free:
    mov eax, [scan_index]
    shr eax, 4
    add eax, [disk_root_start]
    call disk_read_sector
    mov esi, disk_buffer
    mov edi, write_buffer
    mov ecx, 512
    rep movsb
    mov eax, [scan_index]
    and eax, 0x0F
    imul eax, 32
    add eax, write_buffer
    mov dl, [eax]
    cmp dl, 0x00
    je .found_free
    cmp dl, 0xE5
    je .found_free
    inc dword [scan_index]
    loop .find_free
    jmp .error
.found_free:
    mov [current_dir_entry], eax
    call alloc_cluster
    test eax, eax
    jz .error
    mov edi, [current_dir_entry]
    mov ecx, 32
    xor eax, eax
    rep stosb
    mov edi, [current_dir_entry]
    mov ecx, 8
.copy_name:
    lodsb
    cmp al, '.'
    je .pad_name
    cmp al, 0
    je .pad_name
    stosb
    loop .copy_name
.pad_name:
    mov al, ' '
    rep stosb
    mov edi, [current_dir_entry]
    add edi, 8
    mov ecx, 3
    cmp byte [esi - 1], '.'
    jne .no_ext
.copy_ext:
    lodsb
    cmp al, 0
    je .pad_ext
    stosb
    loop .copy_ext
.pad_ext:
    mov al, ' '
    rep stosb
.no_ext:
    pop eax
    mov edi, [current_dir_entry]
    mov [edi + 26], ax
    mov byte [edi + 11], 0x20
    mov eax, [scan_index]
    shr eax, 4
    add eax, [disk_root_start]
    call disk_write_sector
    call scan_root_directory
    call fs_open
    jmp .done
.error:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; =============================================
;  FS_DELETE
; =============================================
fs_delete:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov ecx, [disk_root_entries]
    mov dword [scan_index], 0
.find_file:
    mov eax, [scan_index]
    shr eax, 4
    add eax, [disk_root_start]
    call disk_read_sector
    mov eax, [scan_index]
    and eax, 0x0F
    imul eax, 32
    add eax, disk_buffer
    mov [saved_dir_entry], eax
    mov dl, [eax]
    cmp dl, 0x00
    je .error
    cmp dl, 0xE5
    je .next
    push eax
    mov edi, eax
    mov ecx, 11
    call compare_name
    pop eax
    jne .next
    mov eax, [saved_dir_entry]
    mov dx, [eax + 26]
    movzx ebx, dx
.free_chain:
    push ebx
    call get_next_cluster
    mov eax, ebx
    pop ebx
    push eax
    xor eax, eax
    call write_fat_entry
    pop ebx
    jnc .free_chain
    mov eax, [saved_dir_entry]
    mov byte [eax], 0xE5
    mov eax, [scan_index]
    shr eax, 4
    add eax, [disk_root_start]
    call disk_write_sector
    call scan_root_directory
    mov eax, 1
    jmp .done
.next:
    inc dword [scan_index]
    dec ecx
    jz .error
    jmp .find_file
.error:
    xor eax, eax
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret
; =============================================
;  COMPARE_NAME
; =============================================
compare_name:
    push eax
    push ebx
    push ecx
    push edx
    push esi
    push edi
    mov dword [name_check_count], 0
    mov ecx, 8
.comp_loop:
    lodsb
    cmp al, '.'
    je .skip_to_ext
    cmp al, 0
    je .check_rest
    mov bl, [edi]
    cmp al, bl
    jne .not_equal
    inc edi
    inc dword [name_check_count]
    loop .comp_loop
    jmp .check_ext
.skip_to_ext:
    mov ecx, 8
    sub ecx, [name_check_count]
.skip_name:
    inc edi
    loop .skip_name
.check_rest:
    mov ecx, 8
    sub ecx, [name_check_count]
    cmp ecx, 0
    je .check_ext
.check_rest_loop:
    cmp byte [edi], ' '
    jne .not_equal
    inc edi
    loop .check_rest_loop
.check_ext:
    mov dword [name_check_count], 0
    mov ecx, 3
.ext_loop:
    lodsb
    cmp al, 0
    je .check_ext_rest
    mov bl, [edi]
    cmp al, bl
    jne .not_equal
    inc edi
    inc dword [name_check_count]
    loop .ext_loop
    jmp .equal
.check_ext_rest:
    mov ecx, 3
    sub ecx, [name_check_count]
    cmp ecx, 0
    je .equal
.check_ext_rest_loop:
    cmp byte [edi], ' '
    jne .not_equal
    inc edi
    loop .check_ext_rest_loop
.equal:
    xor eax, eax
    jmp .done
.not_equal:
    or eax, 1
.done:
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop eax
    ret

; =============================================
;  FS_CLOSE
; =============================================
fs_close:
    push eax
    cmp eax, MAX_HANDLES
    ja .done
    dec eax
    mov dword [handles + eax*4], 0
    mov dword [handle_pos + eax*4], 0
    mov dword [handle_size + eax*4], 0
.done:
    pop eax
    ret

; ====================== END ======================
stage5_size equ $ - $$