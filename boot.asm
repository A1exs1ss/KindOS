; boot.asm - KindOS Stage1 [LBA chunked + CHS fallback]

BITS 16
ORG 0x7C00

%define TOT 1000    
%define CHK 127    ; sectors per INT 13h call (BIOS max = 127)

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    mov [drv], dl

    mov ax, 0x0600
    xor cx, cx
    mov dx, 0x184F
    mov bh, 0x07
    int 0x10

    mov si, msg
    call pr

    ; --- LBA probe ---
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [drv]
    int 0x13
    jc .chs
    cmp bx, 0xAA55
    jne .chs
    call lba_read
    jnc .go

.chs:
    mov si, msg_chs
    call pr
    xor ax, ax
    mov dl, [drv]
    int 0x13
    call chs_read
    jnc .go

    mov si, err_msg
    call pr
    xor ah, ah
    int 0x16
    int 0x19

.go:
    mov si, msg_ok
    call pr
    jmp 0x1000:0x0000

; ---- LBA chunked (strict 127 sectors per call) ----
lba_read:
    mov word [dap_seg], 0x1000
    mov word [dap_off], 0
    mov word [left], TOT
.lp:
    mov ax, [left]
    test ax, ax
    jz .ok
    cmp ax, CHK
    jbe .sz
    mov ax, CHK
.sz:
    mov [dap_cnt], ax
    mov [chnk], ax

    ; --- safety: не дать dap_seg дойти до 0xA0000 (VGA) ---
    mov bx, [dap_seg]
    mov cx, ax
    shl cx, 5                ; chnk * 512 / 16 = chnk * 32 (в параграфах)
    add bx, cx
    cmp bx, 0xA000
    ja .fail
    ; ------------------------------------------------------

    mov ah, 0x42
    mov dl, [drv]
    mov si, dap
    int 0x13
    jc .fail

    ; dap_seg += chnk * 32
    mov ax, [chnk]
    shl ax, 5
    add [dap_seg], ax

    ; dap_lba += chnk
    mov ax, [chnk]
    add [dap_lba], ax
    adc word [dap_lba+2], 0
    adc word [dap_lba+4], 0
    adc word [dap_lba+6], 0

    ; left -= chnk
    mov ax, [left]
    sub ax, [chnk]
    mov [left], ax
    jmp .lp
.ok:  clc
      ret
.fail: stc
      ret

; ---- CHS ----
chs_read:
    mov ah, 0x08
    mov dl, [drv]
    int 0x13
    jc .fb
    mov al, cl
    and al, 0x3F
    mov [spt], al
    mov al, dh
    inc al
    mov [hds], al
    jmp .st
.fb:
    mov byte [spt], 63
    mov byte [hds], 16
.st:
    mov ax, 0x1000
    mov es, ax
    xor bx, bx
    mov word [left], TOT
    xor al, al
    mov [cyl], al
    mov [hd], al
    mov byte [sec], 2
.lp:
    cmp word [left], 0
    jz .ok
    mov ah, 0x02
    mov al, 1
    mov ch, [cyl]
    mov cl, [sec]
    mov dh, [hd]
    mov dl, [drv]
    int 0x13
    jc .fail
    mov ax, es
    add ax, 0x20
    mov es, ax
    dec word [left]
    inc byte [sec]
    mov al, [sec]
    cmp al, [spt]
    jbe .lp
    mov byte [sec], 1
    inc byte [hd]
    mov al, [hd]
    cmp al, [hds]
    jb .lp
    mov byte [hd], 0
    inc byte [cyl]
    jmp .lp
.ok:  clc
      ret
.fail: stc
      ret

pr:
    lodsb
    test al, al
    jz .d
    mov ah, 0x0E
    mov bx, 0x000F
    int 0x10
    jmp pr
.d: ret

; ---- data ----
msg     db 'KindOS Stage1...', 13, 10, 0
msg_chs db 'LBA fail. CHS...', 13, 10, 0
msg_ok  db 'Kindrel Loaded!', 13, 10, 0
err_msg db 'Disk error. Press key...', 13, 10, 0

drv  db 0
left dw 0
chnk dw 0
spt  db 0
hds  db 0
cyl  db 0
hd   db 0
sec  db 0

align 16
dap:
    db 0x10
    db 0
dap_cnt: dw 0
dap_off: dw 0
dap_seg: dw 0
dap_lba: dq 1

times 510 - ($ - $$) db 0
dw 0xAA55