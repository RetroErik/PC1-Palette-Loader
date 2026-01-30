; ============================================================================
; PC1PAL.ASM - CGA Palette Override Utility for Olivetti Prodest PC1
; Written for NASM - NEC V40 (80186 compatible)
; By Retro Erik - 2026 using VS Code with Co-Pilot
; Version 0.1
; ============================================================================
; Loads custom RGB palette from config file and writes to V6355D DAC
;
; In CGA 320x200 4-color mode, pixel values 0-3 map to DAC entries based on
; which palette the game uses:
;   Palette 1 (Cyan/Magenta/White):  0, 3/11, 5/13, 7/15 (low/high intensity)
;   Palette 0 (Green/Red/Yellow):    0, 2/10, 4/12, 6/14 (low/high intensity)
;
; This utility writes your 4 custom colors to ALL these positions, so your
; palette works regardless of which CGA palette or intensity the game uses.
;
; Usage: PC1PAL [palette.pal]
;        If no file specified, uses PC1PAL.PAL in current directory
;        If file missing/invalid, uses fallback CGA Mode 4 Palette 1:
;           Color 0: Black, Color 1: Cyan, Color 2: Magenta, Color 3: White
;
; Config file formats supported:
;
;   BINARY (12 bytes exactly):
;     4 RGB triples × 3 bytes each = 12 bytes total
;     Each byte: 0-63 (6-bit value, will be scaled to 3-bit for V6355D)
;     Order: R0,G0,B0, R1,G1,B1, R2,G2,B2, R3,G3,B3
;
;   TEXT (any size > 12 bytes or contains high ASCII):
;     One RGB triple per line: "R,G,B" or "R G B" (values 0-63)
;     Lines starting with ; or # are comments
;     Blank lines are ignored
;     Example:
;       ; My custom palette
;       0,0,0       ; Black
;       0,42,63     ; Sky Blue
;       63,21,0     ; Orange
;       63,63,63    ; White
;
; V6355D Palette Format:
;   Byte 1: Red intensity (bits 0-2, values 0-7)
;   Byte 2: Green (bits 4-6) + Blue (bits 0-2)
;   Note: 6-bit input (0-63) is scaled to 3-bit (0-7) by dividing by 8
;
; Written for NASM (-f bin) - NEC V40 / 8088 compatible
; By Retro Erik - 2026
; ============================================================================

[BITS 16]
[ORG 0x100]

; ============================================================================
; Constants
; ============================================================================

; --- Yamaha V6355D I/O Ports ---
PORT_REG_ADDR   equ 0xDD        ; Register Bank Address Port
PORT_REG_DATA   equ 0xDE        ; Register Bank Data Port

; --- Palette Control Values ---
PAL_WRITE_EN    equ 0x40        ; Write to PORT_REG_ADDR to enable palette write
PAL_WRITE_DIS   equ 0x80        ; Write to PORT_REG_ADDR to disable palette write

; --- File and Buffer Sizes ---
CONFIG_SIZE     equ 12          ; 4 colors × 3 bytes (RGB) = 12 bytes (binary)
PALETTE_ENTRIES equ 4           ; Number of user-defined colors
FULL_PALETTE    equ 16          ; Full V6355D palette (16 colors × 2 bytes = 32 bytes)
TEXT_BUF_SIZE   equ 512         ; Max size for text file reading

; --- CGA Mode 4 Palette Mapping ---
; In CGA 320x200 4-color mode, pixel values 0-3 map to these DAC entries:
;   Palette 1, High Intensity (most common): 0, 11, 13, 15
;   Palette 1, Low Intensity:                0, 3, 5, 7
;   Palette 0, High Intensity:               0, 10, 12, 14
;   Palette 0, Low Intensity:                0, 2, 4, 6
; We write user colors to ALL positions (both palettes, both intensities).

; ============================================================================
; Main Program Entry Point
; ============================================================================
main:
    ; Display startup message
    mov dx, msg_banner
    call print_string
    
    ; Try to load config file
    call load_config
    jc .use_fallback            ; CF set = file error, use defaults
    
    ; Validate the loaded palette data
    call validate_palette
    jc .use_fallback            ; CF set = invalid data
    
    ; Convert 6-bit RGB to V6355D format and write to DAC
    call convert_and_write_palette
    
    ; Success message
    mov dx, msg_success
    call print_string
    jmp .exit

.use_fallback:
    ; Load fallback CGA palette
    mov dx, msg_fallback
    call print_string
    call load_fallback_palette
    call write_palette_to_dac

.exit:
    ; Exit to DOS (return code 0)
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; load_config - Load palette configuration file (binary or text)
; Input:  Command line for filename, or default PC1PAL.PAL
; Output: CF clear = success, config_buffer filled with 12 bytes
;         CF set = error (file not found or parse error)
; ============================================================================
load_config:
    push ax
    push bx
    push cx
    push dx
    
    ; Check command line for filename
    call get_filename
    jc .use_default             ; No filename on command line
    jmp .open_file

.use_default:
    mov dx, default_filename

.open_file:
    ; Open file for reading
    mov ax, 0x3D00
    int 0x21
    jc .file_error
    
    mov [file_handle], ax
    mov bx, ax
    
    ; Read up to TEXT_BUF_SIZE bytes into text_buffer
    mov ah, 0x3F
    mov cx, TEXT_BUF_SIZE
    mov dx, text_buffer
    int 0x21
    jc .close_error
    
    ; Save bytes read
    mov [bytes_read], ax
    
    ; Close file
    mov ah, 0x3E
    mov bx, [file_handle]
    int 0x21
    
    ; Check file size to determine format
    mov ax, [bytes_read]
    cmp ax, CONFIG_SIZE
    jb .close_error             ; Too small for either format
    je .is_binary               ; Exactly 12 bytes = binary format
    
    ; More than 12 bytes - assume text format
    jmp .is_text

.is_binary:
    ; Copy 12 bytes from text_buffer to config_buffer
    mov si, text_buffer
    mov di, config_buffer
    mov cx, CONFIG_SIZE
    cld
    rep movsb
    
    mov dx, msg_loaded_bin
    call print_string
    clc
    jmp .done

.is_text:
    ; Parse text file format
    call parse_text_palette
    jc .parse_error
    
    mov dx, msg_loaded_txt
    call print_string
    clc
    jmp .done

.parse_error:
    mov dx, msg_parse_error
    call print_string
    stc
    jmp .done

.close_error:
    mov ah, 0x3E
    mov bx, [file_handle]
    int 0x21

.file_error:
    mov dx, msg_file_error
    call print_string
    stc

.done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; parse_text_palette - Parse text format palette file
; Input:  text_buffer contains file data, bytes_read = size
; Output: config_buffer filled with 12 bytes (4 RGB triples)
;         CF clear = success, CF set = parse error
;
; Format: One RGB triple per line, comma or space separated
;         Lines starting with ; or # are comments
;         Blank lines are skipped
; ============================================================================
parse_text_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    
    mov si, text_buffer         ; Source: text file data
    mov di, config_buffer       ; Dest: binary RGB data
    mov cx, [bytes_read]        ; Bytes remaining in buffer
    xor bx, bx                  ; BL = colors parsed (0-4)

.next_line:
    ; Check if we have all 4 colors
    cmp bl, 4
    jae .parse_done
    
    ; Check if buffer exhausted
    or cx, cx
    jz .check_count
    
    ; Skip leading whitespace
.skip_ws:
    or cx, cx
    jz .check_count
    lodsb
    dec cx
    cmp al, ' '
    je .skip_ws
    cmp al, 9                   ; Tab
    je .skip_ws
    cmp al, 13                  ; CR
    je .skip_ws
    cmp al, 10                  ; LF
    je .next_line
    
    ; Check for comment line
    cmp al, ';'
    je .skip_to_eol
    cmp al, '#'
    je .skip_to_eol
    
    ; Must be start of a number - parse R,G,B
    ; AL already has first char, back up SI
    dec si
    inc cx
    
    ; Parse Red value
    call parse_number
    jc .parse_fail
    mov [di], al                ; Store Red
    
    ; Skip separator (comma or space)
    call skip_separator
    jc .parse_fail
    
    ; Parse Green value
    call parse_number
    jc .parse_fail
    mov [di+1], al              ; Store Green
    
    ; Skip separator
    call skip_separator
    jc .parse_fail
    
    ; Parse Blue value
    call parse_number
    jc .parse_fail
    mov [di+2], al              ; Store Blue
    
    ; Advance to next color slot
    add di, 3
    inc bl
    
    ; Skip to end of line
    jmp .skip_to_eol

.skip_to_eol:
    or cx, cx
    jz .check_count
    lodsb
    dec cx
    cmp al, 10                  ; LF = end of line
    jne .skip_to_eol
    jmp .next_line

.check_count:
    ; Did we get all 4 colors?
    cmp bl, 4
    jb .parse_fail

.parse_done:
    clc
    jmp .parse_exit

.parse_fail:
    stc

.parse_exit:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; parse_number - Parse a decimal number (0-63) from text
; Input:  SI = pointer to text, CX = bytes remaining
; Output: AL = parsed value (0-63)
;         SI/CX updated past the number
;         CF clear = success, CF set = error
; ============================================================================
parse_number:
    push bx
    push dx
    
    xor ax, ax                  ; Accumulator
    xor bx, bx                  ; Digit count

.digit_loop:
    or cx, cx
    jz .check_digits
    
    mov dl, [si]
    
    ; Check if digit
    cmp dl, '0'
    jb .check_digits
    cmp dl, '9'
    ja .check_digits
    
    ; Accumulate: AX = AX * 10 + digit
    push dx
    mov dx, 10
    mul dx                      ; AX = AX * 10
    pop dx
    
    sub dl, '0'
    xor dh, dh
    add ax, dx
    
    inc si
    dec cx
    inc bx
    jmp .digit_loop

.check_digits:
    ; Must have at least one digit
    or bx, bx
    jz .num_error
    
    ; Value must be 0-63
    cmp ax, 64
    jae .num_error
    
    clc
    jmp .num_done

.num_error:
    stc

.num_done:
    pop dx
    pop bx
    ret

; ============================================================================
; skip_separator - Skip comma, space, or tab between numbers
; Input:  SI = pointer to text, CX = bytes remaining
; Output: SI/CX updated past separators
;         CF clear = found separator, CF set = hit EOL or EOF
; ============================================================================
skip_separator:
    push ax
    
    ; Must have at least one separator
    or cx, cx
    jz .sep_error
    
.sep_loop:
    lodsb
    dec cx
    
    ; Valid separators
    cmp al, ','
    je .sep_more
    cmp al, ' '
    je .sep_more
    cmp al, 9                   ; Tab
    je .sep_more
    
    ; Not a separator - check if EOL (error) or start of next number (ok)
    cmp al, 10
    je .sep_error
    cmp al, 13
    je .sep_error
    
    ; It's the start of next number - back up
    dec si
    inc cx
    clc
    jmp .sep_done

.sep_more:
    ; Continue skipping separators
    or cx, cx
    jz .sep_error
    jmp .sep_loop

.sep_error:
    stc

.sep_done:
    pop ax
    ret

; ============================================================================
; get_filename - Get filename from command line
; Output: DX = pointer to null-terminated filename
;         CF clear = filename found, CF set = no filename
; ============================================================================
get_filename:
    push si
    push di
    
    mov si, 0x81
    mov di, filename_buffer
    
.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_filename
    cmp al, 0x0A
    je .no_filename
    
.copy_loop:
    cmp al, ' '
    je .end_filename
    cmp al, 0x0D
    je .end_filename
    cmp al, 0x0A
    je .end_filename
    
    stosb
    lodsb
    jmp .copy_loop

.end_filename:
    xor al, al
    stosb
    mov dx, filename_buffer
    clc
    jmp .done

.no_filename:
    stc

.done:
    pop di
    pop si
    ret

; ============================================================================
; validate_palette - Validate palette data (all values 0-63)
; Input:  config_buffer contains 12 bytes of RGB data
; Output: CF clear = valid, CF set = invalid
; ============================================================================
validate_palette:
    push cx
    push si
    
    mov si, config_buffer
    mov cx, CONFIG_SIZE

.check_loop:
    lodsb
    cmp al, 64
    jae .invalid
    loop .check_loop
    
    clc
    jmp .done

.invalid:
    mov dx, msg_invalid
    call print_string
    stc

.done:
    pop si
    pop cx
    ret

; ============================================================================
; convert_and_write_palette - Convert 6-bit RGB to V6355D format and write
; Input:  config_buffer contains 4 RGB triples (12 bytes, 0-63 each)
; Output: Palette written to all 16 DAC registers with user colors at:
;         - Entry 0 (background, shared by all modes)
;         - Entries 3, 5, 7 (low intensity palette 1: cyan, magenta, white)
;         - Entries 11, 13, 15 (high intensity palette 1: lt cyan, lt magenta, white)
;         - Entries 2, 4, 6 (low intensity palette 0: green, red, brown)
;         - Entries 10, 12, 14 (high intensity palette 0: lt green, lt red, yellow)
; ============================================================================
convert_and_write_palette:
    push ax
    push bx
    push cx
    push si
    push di
    
    ; First convert user's 4 colors to V6355D format in user_colors buffer
    mov si, config_buffer
    mov di, user_colors
    mov cx, PALETTE_ENTRIES

.convert_loop:
    lodsb                       ; Red (0-63)
    shr al, 3
    and al, 0x07
    mov bl, al
    
    lodsb                       ; Green (0-63)
    shr al, 3
    and al, 0x07
    shl al, 4
    mov bh, al
    
    lodsb                       ; Blue (0-63)
    shr al, 3
    and al, 0x07
    or bh, al
    
    mov al, bl
    stosb                       ; Byte 1: Red
    mov al, bh
    stosb                       ; Byte 2: Green | Blue
    
    loop .convert_loop
    
    ; Now build full 16-color palette
    ; Start with default CGA colors, then override specific entries
    mov si, cga_full_palette
    mov di, palette_buffer
    mov cx, FULL_PALETTE * 2    ; 32 bytes
    cld
    rep movsb
    
    ; Override entry 0 (background) with user color 0
    mov si, user_colors
    mov ax, [si]                ; User color 0
    mov [palette_buffer + 0*2], ax
    
    ; Override palette 1 entries (cyan/magenta/white)
    ; Low intensity: 3, 5, 7
    mov ax, [si + 2]            ; User color 1
    mov [palette_buffer + 3*2], ax
    mov ax, [si + 4]            ; User color 2
    mov [palette_buffer + 5*2], ax
    mov ax, [si + 6]            ; User color 3
    mov [palette_buffer + 7*2], ax
    
    ; High intensity: 11, 13, 15
    mov ax, [si + 2]            ; User color 1
    mov [palette_buffer + 11*2], ax
    mov ax, [si + 4]            ; User color 2
    mov [palette_buffer + 13*2], ax
    mov ax, [si + 6]            ; User color 3
    mov [palette_buffer + 15*2], ax
    
    ; Override palette 0 entries (green/red/brown) for games that use it
    ; Low intensity: 2, 4, 6
    mov ax, [si + 2]            ; User color 1
    mov [palette_buffer + 2*2], ax
    mov ax, [si + 4]            ; User color 2
    mov [palette_buffer + 4*2], ax
    mov ax, [si + 6]            ; User color 3
    mov [palette_buffer + 6*2], ax
    
    ; High intensity: 10, 12, 14
    mov ax, [si + 2]            ; User color 1
    mov [palette_buffer + 10*2], ax
    mov ax, [si + 4]            ; User color 2
    mov [palette_buffer + 12*2], ax
    mov ax, [si + 6]            ; User color 3
    mov [palette_buffer + 14*2], ax
    
    call write_palette_to_dac
    
    pop di
    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; write_palette_to_dac - Write full 16-color palette to V6355D DAC registers
; Input:  palette_buffer contains 32 bytes (16 colors × 2 bytes each)
; Output: All 16 DAC registers updated
; ============================================================================
write_palette_to_dac:
    push ax
    push cx
    push si
    push dx
    
    cli
    
    mov al, PAL_WRITE_EN
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    jmp short $+2
    
    mov si, palette_buffer
    mov cx, FULL_PALETTE * 2    ; 32 bytes for 16 colors
    mov dx, PORT_REG_DATA

.write_loop:
    lodsb
    out dx, al
    jmp short $+2
    loop .write_loop
    
    jmp short $+2
    mov al, PAL_WRITE_DIS
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    
    sti
    
    pop dx
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; write_single_dac_entry - Write a single DAC palette entry
; Input:  AL = palette index (0-15)
;         BL = Red   (0-7, 3-bit)
;         BH = Green (0-7, 3-bit)
;         CL = Blue  (0-7, 3-bit)
; Output: Specified DAC register updated
;
; NOTE: The V6355D requires sequential palette writes starting from index 0.
;       For most uses, writing all 4 CGA entries at once is more efficient.
; REPLACE THIS FUNCTION if your hardware uses different I/O ports.
; ============================================================================
write_single_dac_entry:
    push ax
    push cx
    push dx
    push di
    
    mov ah, al                  ; AH = target index
    
    mov al, bl
    and al, 0x07
    mov [temp_entry], al
    
    mov al, bh
    and al, 0x07
    shl al, 4
    and cl, 0x07
    or al, cl
    mov [temp_entry+1], al
    
    cli
    
    mov al, PAL_WRITE_EN
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    jmp short $+2
    
    xor di, di
    mov dx, PORT_REG_DATA

.dummy_loop:
    cmp di, ax
    shr ax, 8
    cmp di, ax
    jae .write_target
    
    xor al, al
    out dx, al
    jmp short $+2
    out dx, al
    jmp short $+2
    
    inc di
    shl ax, 8
    jmp .dummy_loop

.write_target:
    mov al, [temp_entry]
    out dx, al
    jmp short $+2
    mov al, [temp_entry+1]
    out dx, al
    jmp short $+2
    
    mov al, PAL_WRITE_DIS
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    
    sti
    
    pop di
    pop dx
    pop cx
    pop ax
    ret

temp_entry: db 0, 0

; ============================================================================
; load_fallback_palette - Load default CGA palette into palette_buffer
; Sets all 16 colors to standard CGA, with default cyan/magenta/white for
; entries that CGA mode 4 uses.
; ============================================================================
load_fallback_palette:
    push si
    push di
    push cx
    
    ; Copy full 16-color CGA palette to palette_buffer
    mov si, cga_full_palette
    mov di, palette_buffer
    mov cx, FULL_PALETTE * 2    ; 32 bytes
    cld
    rep movsb
    
    pop cx
    pop di
    pop si
    ret

; ============================================================================
; print_string - Print a $-terminated string
; ============================================================================
print_string:
    push ax
    mov ah, 0x09
    int 0x21
    pop ax
    ret

; ============================================================================
; Data Section
; ============================================================================

msg_banner:
    db 'PC1PAL - CGA Palette Loader for Olivetti PC1', 13, 10
    db 'Yamaha V6355D DAC Programmer', 13, 10, '$'

msg_loaded_bin:
    db 'Binary palette file loaded.', 13, 10, '$'

msg_loaded_txt:
    db 'Text palette file loaded.', 13, 10, '$'

msg_success:
    db 'Palette written to DAC.', 13, 10
    db 'Ready to run CGA programs!', 13, 10, '$'

msg_fallback:
    db 'Using fallback CGA palette.', 13, 10, '$'

msg_file_error:
    db 'Warning: Cannot open palette file.', 13, 10, '$'

msg_parse_error:
    db 'Warning: Cannot parse palette file.', 13, 10, '$'

msg_invalid:
    db 'Warning: Invalid palette data (values must be 0-63).', 13, 10, '$'

default_filename:
    db 'PC1PAL.PAL', 0

; Full 16-color CGA palette (V6355D format, 2 bytes per color)
; Format: Byte1 = Red[2:0], Byte2 = Green[6:4] | Blue[2:0]
cga_full_palette:
    db 0x00, 0x00               ; 0:  Black
    db 0x00, 0x05               ; 1:  Blue
    db 0x00, 0x50               ; 2:  Green
    db 0x00, 0x55               ; 3:  Cyan
    db 0x05, 0x00               ; 4:  Red
    db 0x05, 0x05               ; 5:  Magenta
    db 0x05, 0x20               ; 6:  Brown
    db 0x05, 0x55               ; 7:  Light Gray
    db 0x02, 0x22               ; 8:  Dark Gray
    db 0x02, 0x27               ; 9:  Light Blue
    db 0x02, 0x72               ; 10: Light Green
    db 0x02, 0x77               ; 11: Light Cyan
    db 0x07, 0x22               ; 12: Light Red
    db 0x07, 0x27               ; 13: Light Magenta
    db 0x07, 0x70               ; 14: Yellow
    db 0x07, 0x77               ; 15: White

; Fallback user palette (for when no file loaded)
; Standard CGA Mode 4, Palette 1: Black, Cyan, Magenta, White
cga_default_palette:
    db 0x00, 0x00               ; 0: Black     (R=0, G=0, B=0)
    db 0x00, 0x77               ; 1: Cyan      (R=0, G=7, B=7)
    db 0x07, 0x07               ; 2: Magenta   (R=7, G=0, B=7)
    db 0x07, 0x77               ; 3: White     (R=7, G=7, B=7)

file_handle: dw 0
bytes_read:  dw 0

filename_buffer: times 128 db 0
config_buffer:   times CONFIG_SIZE db 0
user_colors:     times (PALETTE_ENTRIES * 2) db 0   ; Converted user colors (8 bytes)
palette_buffer:  times (FULL_PALETTE * 2) db 0      ; Full 16-color palette (32 bytes)
text_buffer:     times TEXT_BUF_SIZE db 0

; ============================================================================
; End of PC1PAL.ASM
; ============================================================================
