; ============================================================================
; PC1COLOR.ASM - Color Chart Viewer for Olivetti Prodest PC1
; Version 2 - 4x4 Grid picker with arrow-key cursor navigation
; ============================================================================
; Browses all 512 V6355D colors (3-bit RGB), 16 per page across 32 pages.
; Color index = R*64 + G*8 + B   (R,G,B each 0-7)
; DAC byte 1 = R, byte 2 = (G<<4)|B
;
; Controls: Arrows = move cursor, PgUp/PgDn = page, Home/End = skip 10
;           Q / ESC = quit
;
; Layout: 4x4 grid of color swatches, each 18x5 characters.
;         Selected swatch has bright white border. Detail at bottom.
; ============================================================================

[BITS 16]
[CPU 186]
[ORG 0x100]

PORT_REG_ADDR   equ 0xDD
PORT_REG_DATA   equ 0xDE
PAL_WRITE_EN    equ 0x40
PAL_WRITE_DIS   equ 0x80

GRID_TOP        equ 2          ; First grid row on screen
GRID_LEFT       equ 1          ; First grid column
CELL_W          equ 19         ; Cell width in chars
CELL_H          equ 5          ; Cell height in rows
BLOCK_W         equ 16         ; Color block width inside cell
BLOCK_H         equ 3          ; Color block height
DETAIL_ROW      equ 23         ; Row for detail info
FOOTER_ROW      equ 24         ; Row for footer

; ============================================================================
; Main
; ============================================================================
main:
    cld                         ; Clear direction flag for stosw/lodsb
    mov byte [current_page], 0
    mov byte [cursor_pos], 0

.loop:
    call build_palette
    call write_palette
    call draw_screen

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

    ; Extended key?
    or al, al
    jnz .loop

    ; Arrow keys move cursor
    cmp ah, 0x48            ; Up
    je .up
    cmp ah, 0x50            ; Down
    je .down
    cmp ah, 0x4B            ; Left
    je .left
    cmp ah, 0x4D            ; Right
    je .right
    cmp ah, 0x49            ; Page Up
    je .pgup
    cmp ah, 0x51            ; Page Down
    je .pgdn
    cmp ah, 0x47            ; Home
    je .home
    cmp ah, 0x4F            ; End
    je .end_key
    jmp .loop

.up:
    cmp byte [cursor_pos], 4
    jl .loop
    sub byte [cursor_pos], 4
    jmp .loop

.down:
    cmp byte [cursor_pos], 12
    jge .loop
    add byte [cursor_pos], 4
    jmp .loop

.left:
    mov al, [cursor_pos]
    and al, 3
    jz .left_prevpage
    dec byte [cursor_pos]
    jmp .loop
.left_prevpage:
    cmp byte [current_page], 0
    jle .loop
    dec byte [current_page]
    mov al, [cursor_pos]
    or al, 3
    mov [cursor_pos], al
    jmp .loop

.right:
    mov al, [cursor_pos]
    and al, 3
    cmp al, 3
    je .right_nextpage
    inc byte [cursor_pos]
    jmp .loop
.right_nextpage:
    cmp byte [current_page], 31
    jge .loop
    inc byte [current_page]
    mov al, [cursor_pos]
    and al, 0xFC
    mov [cursor_pos], al
    jmp .loop

.pgdn:
    cmp byte [current_page], 31
    jge .loop
    inc byte [current_page]
    jmp .loop

.pgup:
    cmp byte [current_page], 0
    jle .loop
    dec byte [current_page]
    jmp .loop

.end_key:
    mov al, [current_page]
    add al, 10
    cmp al, 31
    jle .end_ok
    mov al, 31
.end_ok:
    mov [current_page], al
    jmp .loop

.home:
    mov al, [current_page]
    sub al, 10
    jge .home_ok
    xor al, al
.home_ok:
    mov [current_page], al
    jmp .loop

.quit:
    call restore_palette
    call cls_screen
    ; Place cursor at top-left via BIOS data area
    mov ax, 0x0040
    mov es, ax
    mov word [es:0x0050], 0     ; Col 0, Row 0
    ; Pick random exit message from BIOS tick counter
    mov ax, [es:0x006C]        ; Low word of timer tick
    and ax, 7                   ; 0..7 (8 messages)
    shl ax, 1                   ; *2 for word table
    mov bx, ax
    mov dx, [bye_table + bx]
    call dos_print
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; cls_screen - Clear screen via VRAM
; ============================================================================
cls_screen:
    push ax
    push cx
    push di
    push es
    mov ax, 0xB800
    mov es, ax
    xor di, di
    mov ax, 0x0720
    mov cx, 2000
    rep stosw
    pop es
    pop di
    pop cx
    pop ax
    ret

; ============================================================================
; draw_screen - Render entire 4x4 grid display via direct VRAM writes
; ============================================================================
draw_screen:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push es

    mov ax, 0xB800
    mov es, ax

    call cls_screen

    ; --- Header row 0 ---
    xor di, di
    mov si, hdr_title
    mov byte [vram_attr], 0x0F     ; Bright white header
    call vram_print_str

    mov al, [current_page]
    inc al
    call vram_print_dec2

    mov si, hdr_of32
    call vram_print_str

    ; Credit text right-aligned on row 0 (col 53)
    mov di, 106                ; Col 53 * 2
    mov si, hdr_credit
    mov byte [vram_attr], 0x07  ; Normal white
    call vram_print_str

    ; --- Row 1: blank (already cleared) ---

    ; --- Draw 4x4 grid ---
    mov byte [grid_idx], 0

.grid_loop:
    ; Row = grid_idx / 4,  Col = grid_idx % 4
    mov al, [grid_idx]
    mov cl, 2
    shr al, cl
    mov [grid_row], al          ; 0..3

    mov al, [grid_idx]
    and al, 3
    mov [grid_col], al          ; 0..3

    ; VRAM offset for cell top-left:
    ; row_offset = (GRID_TOP + grid_row * CELL_H) * 160
    xor ax, ax
    mov al, [grid_row]
    mov bl, CELL_H
    mul bl                      ; AX = grid_row * CELL_H
    add al, GRID_TOP
    mov bl, 160
    mul bl                      ; AX = screen_row * 160
    mov di, ax

    ; col_offset = (GRID_LEFT + grid_col * CELL_W) * 2
    xor ax, ax
    mov al, [grid_col]
    mov bl, CELL_W
    mul bl
    add al, GRID_LEFT
    shl ax, 1
    add di, ax                  ; DI = top-left VRAM offset
    mov [cell_base], di

    ; --- Determine highlight ---
    mov al, [grid_idx]
    cmp al, [cursor_pos]
    je .is_selected
    mov byte [cell_label_attr], 0x07   ; Normal (entry 7 = white)
    jmp .draw_label
.is_selected:
    mov byte [cell_label_attr], 0x0F   ; Bright (entry 15 = white)

.draw_label:
    ; Move DI to label row (no offset for border — border is at bottom)
    mov di, [cell_base]

    ; Print: "xNNN r,g,b       " where x is > for selected, space otherwise
    mov ah, [cell_label_attr]

    ; Selection indicator
    mov al, [grid_idx]
    cmp al, [cursor_pos]
    jne .lbl_nosel
    mov al, 0x10              ; Right-pointing triangle ►
    jmp .lbl_write
.lbl_nosel:
    mov al, ' '
.lbl_write:
    mov ah, [cell_label_attr]
    mov [es:di], ax
    add di, 2

    ; 3-digit color index
    call calc_grid_color        ; [entry_color] = page*16 + grid_idx

    mov ax, [entry_color]
    call vram_put_3digit        ; Uses [cell_label_attr]

    ; Space
    mov ah, [cell_label_attr]
    mov al, ' '
    mov [es:di], ax
    add di, 2

    ; R digit
    mov ax, [entry_color]
    mov cl, 6
    shr ax, cl
    and al, 7
    add al, '0'
    mov ah, [cell_label_attr]
    mov [es:di], ax
    add di, 2

    ; Comma
    mov al, ','
    mov [es:di], ax
    add di, 2

    ; G digit
    mov ax, [entry_color]
    mov cl, 3
    shr ax, cl
    and al, 7
    add al, '0'
    mov ah, [cell_label_attr]
    mov [es:di], ax
    add di, 2

    ; Comma
    mov al, ','
    mov [es:di], ax
    add di, 2

    ; B digit
    mov ax, [entry_color]
    and al, 7
    add al, '0'
    mov ah, [cell_label_attr]
    mov [es:di], ax
    add di, 2

    ; Pad rest of label row with spaces (18 - 11 used = 7)
    mov cx, 7
.lpad:
    mov al, ' '
    mov ah, [cell_label_attr]
    mov [es:di], ax
    add di, 2
    loop .lpad

    ; --- Color block rows ---
    ; cell_base + 160 (label row) = first block row
    mov di, [cell_base]
    add di, 160                 ; Skip label row

    ; BLOCK_H rows of BLOCK_W colored chars
    mov cl, BLOCK_H
.blk_row:
    push cx
    push di
    add di, 2                   ; 1-char indent

    mov al, [grid_idx]         ; Foreground attr = palette entry
    mov cx, BLOCK_W
.blk_col:
    mov byte [es:di], 0xDB
    mov [es:di+1], al
    add di, 2
    loop .blk_col

    pop di
    add di, 160
    pop cx
    dec cl
    jnz .blk_row

    ; --- Bottom border if highlighted ---
    mov al, [grid_idx]
    cmp al, [cursor_pos]
    jne .no_bot

    ; DI is now at row after last block row
    mov cx, 18
    mov ah, 0x0F
    mov al, 0xC4
.hbot:
    mov [es:di], ax
    add di, 2
    loop .hbot
.no_bot:

    ; Next entry
    inc byte [grid_idx]
    cmp byte [grid_idx], 16
    jge .grid_done
    jmp .grid_loop
.grid_done:

    ; --- Detail line (row 23) ---
    mov di, DETAIL_ROW * 160

    mov si, det_color
    mov byte [vram_attr], 0x07
    call vram_print_str

    ; Selected color index
    call calc_cursor_color
    mov ax, [entry_color]
    mov byte [vram_attr], 0x0F
    call vram_put_3digit_v

    ; R:
    mov si, det_r
    mov byte [vram_attr], 0x07
    call vram_print_str
    mov ax, [entry_color]
    mov cl, 6
    shr ax, cl
    and al, 7
    add al, '0'
    mov ah, 0x0F
    mov [es:di], ax
    add di, 2

    ; G:
    mov si, det_g
    mov byte [vram_attr], 0x07
    call vram_print_str
    mov ax, [entry_color]
    mov cl, 3
    shr ax, cl
    and al, 7
    add al, '0'
    mov ah, 0x0F
    mov [es:di], ax
    add di, 2

    ; B:
    mov si, det_b
    mov byte [vram_attr], 0x07
    call vram_print_str
    mov ax, [entry_color]
    and al, 7
    add al, '0'
    mov ah, 0x0F
    mov [es:di], ax
    add di, 2

    ; Preview swatch at end of detail row: 12 chars wide
    mov di, DETAIL_ROW * 160 + 120   ; Col 60
    mov al, [cursor_pos]
    mov cx, 12
.preview:
    mov byte [es:di], 0xDB
    mov [es:di+1], al
    add di, 2
    loop .preview

    ; --- Footer (row 24) ---
    mov di, FOOTER_ROW * 160
    mov si, msg_footer
    mov byte [vram_attr], 0x07     ; Normal footer (entry 7 = white)
    call vram_print_str

    pop es
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; calc_grid_color - entry_color = page*16 + grid_idx
; ============================================================================
calc_grid_color:
    push ax
    push bx
    push cx
    xor ax, ax
    mov al, [current_page]
    mov cl, 4
    shl ax, cl
    xor bx, bx
    mov bl, [grid_idx]
    add ax, bx
    mov [entry_color], ax
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; calc_cursor_color - entry_color = page*16 + cursor_pos
; ============================================================================
calc_cursor_color:
    push ax
    push bx
    push cx
    xor ax, ax
    mov al, [current_page]
    mov cl, 4
    shl ax, cl
    xor bx, bx
    mov bl, [cursor_pos]
    add ax, bx
    mov [entry_color], ax
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; vram_print_str - Print null-terminated string at ES:DI, attr [vram_attr]
; ============================================================================
vram_print_str:
    push ax
    push si
    mov ah, [vram_attr]
.lp:
    lodsb
    or al, al
    jz .dn
    mov [es:di], ax
    add di, 2
    jmp .lp
.dn:
    pop si
    pop ax
    ret

; ============================================================================
; vram_print_dec2 - Print AL as 2-digit decimal at ES:DI, attr [vram_attr]
; ============================================================================
vram_print_dec2:
    push ax
    push dx
    xor ah, ah
    mov dl, 10
    div dl
    push ax
    add al, '0'
    mov ah, [vram_attr]
    mov [es:di], ax
    add di, 2
    pop ax
    mov al, ah
    add al, '0'
    mov ah, [vram_attr]
    mov [es:di], ax
    add di, 2
    pop dx
    pop ax
    ret

; ============================================================================
; vram_put_3digit - Print AX (0-511) as 3 digits, attr [cell_label_attr]
; ============================================================================
vram_put_3digit:
    push ax
    push bx
    push dx
    xor dx, dx
    mov bx, 100
    div bx
    push dx
    add al, '0'
    mov ah, [cell_label_attr]
    mov [es:di], ax
    add di, 2
    pop ax
    xor dx, dx
    mov bl, 10
    div bl
    push ax
    add al, '0'
    mov ah, [cell_label_attr]
    mov [es:di], ax
    add di, 2
    pop ax
    mov al, ah
    add al, '0'
    mov ah, [cell_label_attr]
    mov [es:di], ax
    add di, 2
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; vram_put_3digit_v - Print AX (0-511) as 3 digits, attr [vram_attr]
; ============================================================================
vram_put_3digit_v:
    push ax
    push bx
    push dx
    xor dx, dx
    mov bx, 100
    div bx
    push dx
    add al, '0'
    mov ah, [vram_attr]
    mov [es:di], ax
    add di, 2
    pop ax
    xor dx, dx
    mov bl, 10
    div bl
    push ax
    add al, '0'
    mov ah, [vram_attr]
    mov [es:di], ax
    add di, 2
    pop ax
    mov al, ah
    add al, '0'
    mov ah, [vram_attr]
    mov [es:di], ax
    add di, 2
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; dos_print - Print '$'-terminated string via DOS (exit only)
; ============================================================================
dos_print:
    push ax
    mov ah, 0x09
    int 0x21
    pop ax
    ret

; ============================================================================
; build_palette - Build 16-entry DAC palette for current page
; Entry 0 = forced black (background), 7 and 15 = forced white (text)
; ============================================================================
build_palette:
    push ax
    push bx
    push cx
    push dx
    push si

    mov si, 0
    mov bx, palette_buffer

.entry:
    cmp si, 0
    je .black
    cmp si, 7
    je .white
    cmp si, 15
    je .white

    xor ax, ax
    mov al, [current_page]
    mov cl, 4
    shl ax, cl
    add ax, si

    ; Byte 1: R
    mov dx, ax
    mov cl, 6
    shr ax, cl
    and al, 0x07
    mov [bx], al
    inc bx

    ; Byte 2: (G<<4)|B
    mov ax, dx
    mov cl, 3
    shr ax, cl
    and al, 0x07
    mov cl, 4
    shl al, cl
    mov ah, al
    mov al, dl
    and al, 0x07
    or al, ah
    mov [bx], al
    inc bx
    jmp .next

.white:
    mov byte [bx], 0x07
    inc bx
    mov byte [bx], 0x77
    inc bx
    jmp .next

.black:
    mov byte [bx], 0x00
    inc bx
    mov byte [bx], 0x00
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
; write_palette - Write palette_buffer to V6355D DAC
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
; Data
; ============================================================================

current_page:   db 0
cursor_pos:     db 0
palette_buffer: times 32 db 0

grid_idx:       db 0
grid_row:       db 0
grid_col:       db 0
cell_base:      dw 0
cell_label_attr: db 0
entry_color:    dw 0
vram_attr:      db 0x07

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

hdr_title:  db 'PC1COLOR v2  Page ', 0
hdr_of32:   db '/32', 0
hdr_credit: db 'Created by Retro Erik 2026', 0

det_color:  db 'Color: ', 0
det_r:      db '  R:', 0
det_g:      db ' G:', 0
det_b:      db ' B:', 0

msg_footer: db 'Arrows=Move  PgUp/Dn=Page  Home/End=Skip10  Q=Quit', 0

bye_table:
    dw bye_0, bye_1, bye_2, bye_3, bye_4, bye_5, bye_6, bye_7
bye_0: db 'The Yamaha V6355D thanks you for your visit.', 13, 10, '$'
bye_1: db 'So long, and thanks for all the colors.', 13, 10, '$'
bye_2: db 'The answer to life, the universe and everything is 512...', 13, 10, '$'
bye_3: db "DON'T PANIC. The palette has been restored.", 13, 10, '$'
bye_4: db 'Time is an illusion. Color selection doubly so.', 13, 10, '$'
bye_5: db 'Roger Wilco was here. He mopped up your palette.', 13, 10, '$'
bye_6: db 'Larry looked at 512 colors. None of them were interested.', 13, 10, '$'
bye_7: db "You can't do that. Oh wait, you just did. Goodbye!", 13, 10, '$'
