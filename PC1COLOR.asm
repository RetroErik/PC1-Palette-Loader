; ============================================================================
; PC1COLOR.ASM - Color Chart Viewer for Olivetti Prodest PC1
; Version 1.6 - Based EXACTLY on working v1.3 structure
; Not working - yet
; ============================================================================

[BITS 16]
[ORG 0x100]

PORT_REG_ADDR   equ 0xDD
PORT_REG_DATA   equ 0xDE
PAL_WRITE_EN    equ 0x40
PAL_WRITE_DIS   equ 0x80

; ============================================================================
; Main
; ============================================================================
main:
    mov byte [current_page], 0

main_loop:
    ; Banner
    mov dx, msg_banner
    mov ah, 0x09
    int 0x21
    
    ; Page info - proper 2-digit
    mov dx, msg_page
    mov ah, 0x09
    int 0x21
    xor ax, ax
    mov al, [current_page]
    inc al                  ; 1-based
    call print_num
    mov dx, msg_of32
    mov ah, 0x09
    int 0x21
    
    ; Build palette
    call build_palette
    call write_palette
    
    ; Show 16 colors - EXACTLY like v1.3
    call show_colors
    
    ; Footer
    mov dx, msg_footer
    mov ah, 0x09
    int 0x21
    
    ; Get key
    mov ah, 0x00
    int 0x16
    
    ; Quit?
    cmp al, 'q'
    je quit
    cmp al, 'Q'
    je quit
    cmp al, 27
    je quit
    
    ; Space = next
    cmp al, ' '
    je next_page
    
    ; Extended key?
    or al, al
    jnz main_loop
    
    cmp ah, 0x4D            ; Right
    je next_page
    cmp ah, 0x4B            ; Left
    je prev_page
    jmp main_loop

next_page:
    cmp byte [current_page], 31
    jge main_loop
    inc byte [current_page]
    jmp main_loop

prev_page:
    cmp byte [current_page], 0
    jle main_loop
    dec byte [current_page]
    jmp main_loop

quit:
    mov dx, msg_bye
    mov ah, 0x09
    int 0x21
    call restore_palette
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; build_palette - EXACTLY like v1.3 but with page offset
; ============================================================================
build_palette:
    push ax
    push bx
    push di
    
    mov di, palette_buffer
    xor bx, bx              ; Entry 0-15
    
bp_loop:
    ; Keep 7 and 15 white
    cmp bx, 7
    je bp_white
    cmp bx, 15
    je bp_white
    
    ; Color = page*16 + entry
    xor ax, ax
    mov al, [current_page]
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1               ; *16
    add ax, bx              ; + entry
    
    ; Byte 1: R (index >> 6) & 7
    push ax
    push ax
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1               ; >> 6
    and al, 0x07
    stosb
    
    ; Byte 2: (G << 4) | B
    pop ax
    push ax
    shr ax, 1
    shr ax, 1
    shr ax, 1               ; >> 3 for G
    and al, 0x07
    shl al, 1
    shl al, 1
    shl al, 1
    shl al, 1               ; << 4
    mov ah, al              ; G in AH
    
    pop ax                  ; Original color
    and al, 0x07            ; B
    or al, ah               ; G | B
    stosb
    
    pop ax                  ; Balance stack
    jmp bp_next

bp_white:
    mov al, 0x07
    stosb
    mov al, 0x77
    stosb

bp_next:
    inc bx
    cmp bx, 16
    jl bp_loop
    
    pop di
    pop bx
    pop ax
    ret

; ============================================================================
; write_palette - EXACT copy from working v1.3
; ============================================================================
write_palette:
    push ax
    push cx
    push dx
    push si
    
    cli
    
    mov al, PAL_WRITE_EN
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    jmp short $+2
    
    mov si, palette_buffer
    mov cx, 32
    mov dx, PORT_REG_DATA
    
wp_loop:
    lodsb
    out dx, al
    jmp short $+2
    loop wp_loop
    
    jmp short $+2
    mov al, PAL_WRITE_DIS
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    
    sti
    
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; restore_palette - EXACT copy from working v1.3
; ============================================================================
restore_palette:
    push ax
    push cx
    push dx
    push si
    
    cli
    
    mov al, PAL_WRITE_EN
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    jmp short $+2
    
    mov si, cga_palette
    mov cx, 32
    mov dx, PORT_REG_DATA
    
rp_loop:
    lodsb
    out dx, al
    jmp short $+2
    loop rp_loop
    
    jmp short $+2
    mov al, PAL_WRITE_DIS
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    
    sti
    
    pop si
    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; show_colors - Show 16 colors with ACTUAL RGB values and color blocks
; Uses memory variables to avoid register corruption from INT calls
; ============================================================================
show_colors:
    push ax
    push bx
    push dx
    
    ; Calculate base: page * 16
    xor ax, ax
    mov al, [current_page]
    shl ax, 1
    shl ax, 1
    shl ax, 1
    shl ax, 1               ; * 16
    mov [sc_base], ax
    
    mov byte [sc_entry], 0
    
sc_loop:
    ; Print colored block (4 chars)
    mov al, 219             ; Solid block char
    mov bl, [sc_entry]      ; Attribute = entry number (0-15)
    mov bh, 0               ; Page 0
    mov cx, 4               ; 4 blocks
    mov ah, 0x09            ; Write char with attr
    int 0x10
    
    ; Move cursor forward 4 positions
    mov ah, 0x03            ; Get cursor position
    mov bh, 0
    int 0x10                ; DH=row, DL=column
    add dl, 4
    mov ah, 0x02            ; Set cursor position
    int 0x10
    
    ; Actual color = base + entry
    mov ax, [sc_base]
    xor bx, bx
    mov bl, [sc_entry]
    add ax, bx
    mov [sc_color], ax
    
    ; Print entry number (2-digit)
    call print_num
    
    mov dx, msg_r
    mov ah, 0x09
    int 0x21
    
    ; R value = (color >> 6) & 7
    mov ax, [sc_color]
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    shr ax, 1
    and al, 7
    add al, '0'
    mov dl, al
    mov ah, 0x02
    int 0x21
    
    mov dx, msg_g
    mov ah, 0x09
    int 0x21
    
    ; G value = (color >> 3) & 7
    mov ax, [sc_color]
    shr ax, 1
    shr ax, 1
    shr ax, 1
    and al, 7
    add al, '0'
    mov dl, al
    mov ah, 0x02
    int 0x21
    
    mov dx, msg_b
    mov ah, 0x09
    int 0x21
    
    ; B value = color & 7
    mov ax, [sc_color]
    and al, 7
    add al, '0'
    mov dl, al
    mov ah, 0x02
    int 0x21
    
    mov dx, msg_crlf
    mov ah, 0x09
    int 0x21
    
    inc byte [sc_entry]
    cmp byte [sc_entry], 16
    jl sc_loop
    
    pop dx
    pop bx
    pop ax
    ret

; Variables for show_colors
sc_base:    dw 0
sc_entry:   db 0
sc_color:   dw 0

; ============================================================================
; print_num - EXACT copy from working v1.3
; ============================================================================
print_num:
    push ax
    push dx
    
    xor ah, ah
    mov dl, 10
    div dl                  ; AL=tens, AH=ones
    push ax
    
    add al, '0'
    mov dl, al
    mov ah, 0x02
    int 0x21
    
    pop ax
    mov al, ah
    add al, '0'
    mov dl, al
    mov ah, 0x02
    int 0x21
    
    pop dx
    pop ax
    ret

; ============================================================================
; Data
; ============================================================================

current_page:   db 0
palette_buffer: times 32 db 0

cga_palette:
    db 0x00, 0x00
    db 0x00, 0x05
    db 0x00, 0x50
    db 0x00, 0x55
    db 0x05, 0x00
    db 0x05, 0x05
    db 0x05, 0x20
    db 0x05, 0x55
    db 0x02, 0x22
    db 0x02, 0x27
    db 0x02, 0x72
    db 0x02, 0x77
    db 0x07, 0x22
    db 0x07, 0x27
    db 0x07, 0x70
    db 0x07, 0x77

msg_banner: db 'PC1COLOR v1.6', 13, 10, '$'
msg_page:   db 'Page $'
msg_of32:   db '/32', 13, 10, '$'
msg_r:      db ': R:$'
msg_g:      db ' G:$'
msg_b:      db ' B:$'
msg_crlf:   db 13, 10, '$'
msg_footer: db '-----', 13, 10, 'Space/Arrows:Page Q:Quit', 13, 10, '$'
msg_bye:    db 'Bye!', 13, 10, '$'
