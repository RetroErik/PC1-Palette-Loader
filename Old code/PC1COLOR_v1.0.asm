; ============================================================================
; PC1COLOR.ASM - Color Chart Viewer for Olivetti Prodest PC1
; Version 1 - Side-by-side 8-wide blocks, PgUp/PgDn jump 10 pages
; ============================================================================
; Browses all 512 V6355D colors (3-bit RGB), 16 per page across 32 pages.
; Color index = R*64 + G*8 + B   (R,G,B each 0-7)
; DAC byte 1 = R, byte 2 = (G<<4)|B
;
; Controls: Space/Right = next page, Left = prev page, Q/ESC = quit
; ============================================================================

[BITS 16]
[CPU 186]
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

.loop:
    ; Print banner + page header using DOS only
    call print_header

    ; Build and write custom palette for this page
    call build_palette
    call write_palette

    ; Show 16 color entries (block + RGB info)
    call show_colors

    ; Footer
    mov dx, msg_footer
    call dos_print

    ; Wait for key
    xor ax, ax
    int 0x16

    ; Quit?
    cmp al, 'q'
    je .quit
    cmp al, 'Q'
    je .quit
    cmp al, 27
    je .quit

    ; Space or Enter = next
    cmp al, ' '
    je .next
    cmp al, 13
    je .next

    ; Extended key?
    or al, al
    jnz .loop
    cmp ah, 0x4D            ; Right arrow
    je .next
    cmp ah, 0x4B            ; Left arrow
    je .prev
    cmp ah, 0x49            ; Page Up
    je .pgup
    cmp ah, 0x51            ; Page Down
    je .pgdn
    jmp .loop

.next:
    cmp byte [current_page], 31
    jge .loop
    inc byte [current_page]
    jmp .loop

.prev:
    cmp byte [current_page], 0
    jle .loop
    dec byte [current_page]
    jmp .loop

.pgdn:
    mov al, [current_page]
    add al, 10
    cmp al, 31
    jle .pgdn_ok
    mov al, 31
.pgdn_ok:
    mov [current_page], al
    jmp .loop

.pgup:
    mov al, [current_page]
    sub al, 10
    jge .pgup_ok
    xor al, al
.pgup_ok:
    mov [current_page], al
    jmp .loop

.quit:
    call restore_palette
    mov dx, msg_bye
    call dos_print
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; dos_print - Print '$'-terminated string via DOS
; Input: DX = string pointer
; ============================================================================
dos_print:
    push ax
    mov ah, 0x09
    int 0x21
    pop ax
    ret

; ============================================================================
; dos_char - Print single character via DOS
; Input: DL = character
; ============================================================================
dos_char:
    push ax
    mov ah, 0x02
    int 0x21
    pop ax
    ret

; ============================================================================
; print_header - Clear screen (via newlines) and print banner + page info
; ============================================================================
print_header:
    push ax
    push cx
    push dx

    ; Clear screen: 25 blank lines to scroll old content away
    mov cx, 25
.cls:
    mov dx, msg_crlf
    call dos_print
    loop .cls

    ; Banner
    mov dx, msg_banner
    call dos_print

    ; "Page NN/32"
    mov dx, msg_page
    call dos_print
    mov al, [current_page]
    inc al                   ; 1-based display
    call print_decimal
    mov dx, msg_of32
    call dos_print

    pop dx
    pop cx
    pop ax
    ret

; ============================================================================
; build_palette - Build 16-entry DAC palette for current page
; NO stosb - uses explicit [bx] memory writes (DS-relative)
; Entries 7 and 15 kept white for readable text (attr 7 = normal text)
; ============================================================================
build_palette:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, 0               ; SI = entry index 0..15
    mov bx, palette_buffer  ; BX = write pointer

.entry:
    ; Keep entry 0 black (background), 7 and 15 white (text)
    cmp si, 0
    je .black
    cmp si, 7
    je .white
    cmp si, 15
    je .white

    ; Color index = page * 16 + entry
    xor ax, ax
    mov al, [current_page]
    mov cl, 4
    shl ax, cl               ; * 16
    add ax, si               ; + entry
    ; AX = color index (0..511)

    ; Byte 1: R = (index >> 6) & 7
    mov dx, ax               ; Save color index in DX
    mov cl, 6
    shr ax, cl
    and al, 0x07
    mov [bx], al
    inc bx

    ; Byte 2: (G << 4) | B
    mov ax, dx               ; Restore color index
    mov cl, 3
    shr ax, cl               ; >> 3 for G field
    and al, 0x07
    mov cl, 4
    shl al, cl               ; G << 4
    mov ah, al               ; Save G<<4 in AH
    mov al, dl               ; Original color low byte
    and al, 0x07             ; B field
    or al, ah                ; (G<<4) | B
    mov [bx], al
    inc bx

    jmp .next

.white:
    mov byte [bx], 0x07     ; R=7
    inc bx
    mov byte [bx], 0x77     ; G=7, B=7
    inc bx
    jmp .next

.black:
    mov byte [bx], 0x00     ; R=0
    inc bx
    mov byte [bx], 0x00     ; G=0, B=0
    inc bx

.next:
    inc si
    cmp si, 16
    jl .entry

    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; write_palette - Write 32-byte palette_buffer to V6355D DAC
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

.wr:
    lodsb
    out dx, al
    jmp short $+2
    loop .wr

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
; restore_palette - Restore standard CGA palette
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

.wr:
    lodsb
    out dx, al
    jmp short $+2
    loop .wr

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
; show_colors - Side-by-side display: 8 rows, entries 0-7 left / 8-15 right
; Layout: " NN: R:r G:g B:b  ████ ████  NN: R:r G:g B:b"
;          left info          L-blk R-blk  right info
; Color blocks at col 18 (left) and col 23 (right) via VRAM.
; ============================================================================
show_colors:
    push ax
    push bx
    push cx
    push dx
    push si
    push es

    ; Base color index = page * 16
    xor ax, ax
    mov al, [current_page]
    mov cl, 4
    shl ax, cl
    mov [sc_base], ax

    ; --- PASS 1: Print 8 rows of text via DOS ---
    mov byte [sc_entry], 0

.textrow:
    ; === LEFT SIDE: " NN: R:r G:g B:b" (cols 0-15) ===
    mov dl, ' '
    call dos_char

    mov al, [sc_entry]
    call print_decimal

    ; Left color = base + entry
    mov ax, [sc_base]
    xor bx, bx
    mov bl, [sc_entry]
    add ax, bx
    mov [sc_color], ax

    mov dx, msg_r
    call dos_print
    mov ax, [sc_color]
    mov cl, 6
    shr ax, cl
    and al, 7
    add al, '0'
    mov dl, al
    call dos_char

    mov dx, msg_g
    call dos_print
    mov ax, [sc_color]
    mov cl, 3
    shr ax, cl
    and al, 7
    add al, '0'
    mov dl, al
    call dos_char

    mov dx, msg_b
    call dos_print
    mov ax, [sc_color]
    and al, 7
    add al, '0'
    mov dl, al
    call dos_char

    ; === MIDDLE: 19 spaces for block area (cols 17-35) ===
    mov dx, msg_blockgap
    call dos_print

    ; === RIGHT SIDE: "NN: R:r G:g B:b" (cols 29+) ===
    mov al, [sc_entry]
    add al, 8
    call print_decimal

    ; Right color = base + entry + 8
    mov ax, [sc_base]
    xor bx, bx
    mov bl, [sc_entry]
    add bx, 8
    add ax, bx
    mov [sc_color], ax

    mov dx, msg_r
    call dos_print
    mov ax, [sc_color]
    mov cl, 6
    shr ax, cl
    and al, 7
    add al, '0'
    mov dl, al
    call dos_char

    mov dx, msg_g
    call dos_print
    mov ax, [sc_color]
    mov cl, 3
    shr ax, cl
    and al, 7
    add al, '0'
    mov dl, al
    call dos_char

    mov dx, msg_b
    call dos_print
    mov ax, [sc_color]
    and al, 7
    add al, '0'
    mov dl, al
    call dos_char

    mov dx, msg_crlf
    call dos_print

    inc byte [sc_entry]
    cmp byte [sc_entry], 8
    jge .textdone
    jmp .textrow
.textdone:

    ; --- PASS 2: Paint colored blocks into VRAM ---
    ; Cursor is now after 8 text rows. Subtract 8 to find first row.
    mov ax, 0x0040
    mov es, ax
    mov al, [es:0x0051]
    sub al, 8
    mov [sc_startrow], al

    mov ax, 0xB800
    mov es, ax

    mov byte [sc_entry], 0

.paintrow:
    ; Calculate VRAM offset for this row
    xor ax, ax
    mov al, [sc_startrow]
    add al, [sc_entry]
    mov bx, 160
    mul bx
    mov si, ax               ; SI = row start in VRAM

    ; Left block: 8 chars at col 18 (offset +36): entry 0-7
    mov al, 0xDB
    mov ah, [sc_entry]       ; Foreground = entry 0-7
    mov [es:si+36], ax
    mov [es:si+38], ax
    mov [es:si+40], ax
    mov [es:si+42], ax
    mov [es:si+44], ax
    mov [es:si+46], ax
    mov [es:si+48], ax
    mov [es:si+50], ax

    ; Right block: 8 chars at col 27 (offset +54): entry 8-15
    mov al, 0xDB
    mov ah, [sc_entry]
    add ah, 8                ; Foreground = entry 8-15
    mov [es:si+54], ax
    mov [es:si+56], ax
    mov [es:si+58], ax
    mov [es:si+60], ax
    mov [es:si+62], ax
    mov [es:si+64], ax
    mov [es:si+66], ax
    mov [es:si+68], ax

    inc byte [sc_entry]
    cmp byte [sc_entry], 8
    jl .paintrow

    pop es
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; print_decimal - Print AL as 2-digit decimal (00-99)
; ============================================================================
print_decimal:
    push ax
    push dx

    xor ah, ah
    mov dl, 10
    div dl                  ; AL=tens, AH=ones
    push ax                 ; Save for ones digit

    add al, '0'
    mov dl, al
    call dos_char           ; Print tens

    pop ax
    mov al, ah
    add al, '0'
    mov dl, al
    call dos_char           ; Print ones

    pop dx
    pop ax
    ret

; ============================================================================
; Data
; ============================================================================

current_page:   db 0
palette_buffer: times 32 db 0

; Variables for show_colors (in data area, safe from any stack issues)
sc_base:        dw 0
sc_entry:       db 0
sc_color:       dw 0
sc_startrow:    db 0

cga_palette:
    db 0x00, 0x00       ; 0  Black
    db 0x00, 0x05       ; 1  Blue
    db 0x00, 0x50       ; 2  Green
    db 0x00, 0x55       ; 3  Cyan
    db 0x05, 0x00       ; 4  Red
    db 0x05, 0x05       ; 5  Magenta
    db 0x05, 0x20       ; 6  Brown
    db 0x05, 0x55       ; 7  Light Gray
    db 0x02, 0x22       ; 8  Dark Gray
    db 0x02, 0x27       ; 9  Light Blue
    db 0x02, 0x72       ; 10 Light Green
    db 0x02, 0x77       ; 11 Light Cyan
    db 0x07, 0x22       ; 12 Light Red
    db 0x07, 0x27       ; 13 Light Magenta
    db 0x07, 0x70       ; 14 Yellow
    db 0x07, 0x77       ; 15 White

msg_banner: db 'PC1COLOR v1', 13, 10, '$'
msg_page:   db 'Page $'
msg_of32:   db '/32', 13, 10, '$'
msg_r:      db ': R:$'
msg_g:      db ' G:$'
msg_b:      db ' B:$'
msg_crlf:   db 13, 10, '$'
msg_blockgap: db '                   $'  ; 19 spaces (1+8+1+8+1)
msg_footer: db '---', 13, 10
            db 'Space/Right/Left PgUp/PgDn Q=Quit', 13, 10, '$'
msg_bye:    db 'Bye!', 13, 10, '$'
