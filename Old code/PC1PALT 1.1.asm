; ============================================================================
; PC1PALT.ASM - CGA Palette TSR for Olivetti Prodest PC1
; Written for NASM - NEC V40 (80186 compatible)
; By Retro Erik - 2026 using VS Code with GitHub Copilot
; Version 1.1 - TSR with Ctrl+Alt hotkeys
; ============================================================================
;
; Loads custom RGB palettes and programs the Yamaha V6355D DAC, then stays
; resident to survive game mode resets and provide live palette adjustment.
;
; Based on PC1PAL v0.9 (one-shot palette loader) and PalSwapT v3.3 (CGA
; Palette TSR for VGA/EGA), adapted for the Olivetti Prodest PC1's V6355D
; Display Adapter Controller.
;
; FEATURES:
;   - TSR: hooks INT 10h to re-apply palette after CGA mode 4/5 resets
;   - Live hotkeys via INT 09h (Ctrl+Alt + key):
;       1..9         Load preset palette 1-9
;       P            Toggle Pop (saturation + contrast boost)
;       R            Reset to default CGA palette
;       Up / Down    Brighten / Dim (+/-8 per step, max 3 steps)
;       Left / Right Less vivid / More vivid (saturation, max 3 steps)
;       Space        Random palette from 15 CGA colors (excludes black)
;       C            Random palette from 15 C64 colors
;       A            Random palette from 26 Amstrad CPC colors
;       Z            Random palette from 14 ZX Spectrum colors
;     Release Ctrl+Alt to return to normal — all keys pass through.
;
; BUILT-IN PRESETS:
;     /1  Arcade Vibrant     /2  Sierra Natural     /3  C64-inspired
;     /4  CGA Red/Green      /5  CGA Red/Blue       /6  Amstrad CPC
;     /7  Pastel             /8  Mono Amber          /9  Mono Green
;
; COMMAND LINE:
;   PC1PALT [file.txt] [/1..9] [/c:c1,c2,c3] [/b:color]
;                       [/P] [/V:+|-] [/D:+|-] [/R] [/U] [/?]
;
; HOW IT WORKS:
;   1. Run PC1PALT with your palette choice before starting a game.
;   2. PC1PALT loads the palette, hooks INT 09h + INT 10h, stays resident.
;   3. When a game calls INT 10h AH=00h AL=04h/05h (set CGA mode):
;      - The original handler sets the mode.
;      - Our hook re-programs the V6355D DAC with the custom palette.
;   4. Hold Ctrl+Alt + hotkeys for live adjustment while the game runs.
;   5. Re-run PC1PALT with new arguments to update the resident palette.
;   6. Run "PC1PALT /U" to uninstall.
;
; V6355D PALETTE FORMAT:
;   Byte 1: Red intensity (bits 0-2, values 0-7)
;   Byte 2: Green (bits 4-6) | Blue (bits 0-2)
;   Input: 6-bit (0-63) scaled to 3-bit (0-7) by dividing by 8
;
; CGA MODE 4 PIXEL -> DAC ENTRY MAPPING (all 16 entries programmed):
;   Entry 0  = color 0 (background)
;   Entry 1  = color 1              Entry 8  = color 2
;   Entry 2  = color 1 (pal0 low)   Entry 9  = color 3
;   Entry 3  = color 1 (pal1 low)   Entry 10 = color 1 (pal0 high)
;   Entry 4  = color 2 (pal0 low)   Entry 11 = color 1 (pal1 high)
;   Entry 5  = color 2 (pal1 low)   Entry 12 = color 2 (pal0 high)
;   Entry 6  = color 3 (pal0 low)   Entry 13 = color 2 (pal1 high)
;   Entry 7  = color 3 (pal1 low)   Entry 14 = color 3 (pal0 high)
;                                    Entry 15 = color 3 (pal1 high)
;
; IMPORTANT - far-pointer layout in resident data:
;   orig_int10_ofs MUST come before orig_int10_seg in memory because
;   "jmp/call far [mem]" reads offset then segment.
;   Same for orig_int09_ofs / orig_int09_seg.
;
; TSR SIZE:
;   Computed at runtime as  (offset_of_tsr_end + 15) / 16  paragraphs.
;   ORG 0x100 means label offsets already include the 256-byte PSP.
;
; ============================================================================

[BITS 16]
[ORG 0x100]
CPU 186

; ============================================================================
; Constants
; ============================================================================

; --- Yamaha V6355D I/O Ports ---
PORT_REG_ADDR       equ 0xDD        ; Register Bank Address Port
PORT_REG_DATA       equ 0xDE        ; Register Bank Data Port
PAL_WRITE_EN        equ 0x40        ; Enable palette write
PAL_WRITE_DIS       equ 0x80        ; Disable palette write

; --- Palette sizes ---
CONFIG_SIZE         equ 12          ; 4 colors x 3 bytes (single palette RGB)
PALETTE_ENTRIES     equ 4           ; User-defined colors
FULL_PALETTE        equ 16          ; V6355D palette entries
MAX_PALETTES        equ 9           ; Max palettes in a multi-palette file
MULTI_CONFIG_SIZE   equ 108         ; 9 x 12 bytes
TEXT_BUF_SIZE       equ 1024

; --- Keyboard scan codes ---
SCAN_1              equ 0x02
SCAN_9              equ 0x0A
SCAN_P              equ 0x19
SCAN_R              equ 0x13
SCAN_UP             equ 0x48
SCAN_DOWN           equ 0x50
SCAN_LEFT           equ 0x4B
SCAN_RIGHT          equ 0x4D
SCAN_SPACE          equ 0x39
SCAN_C              equ 0x2E
SCAN_A              equ 0x1E
SCAN_Z              equ 0x2C

; --- BIOS keyboard flag bits at 0040:0017h ---
CTRLALT_BITS        equ 0x0C        ; Ctrl(0x04) + Alt(0x08) both held

; --- Adjustment limits ---
MAX_BRIGHT_LEVEL    equ 3
MAX_VIVID_LEVEL     equ 3

; ============================================================================
; Jump over resident section to installer
; ============================================================================
jmp main

; ============================================================================
; =====================  RESIDENT SECTION  ===================================
; ============================================================================
; Everything from here to tsr_end stays in memory after going TSR.
; ============================================================================

; --- TSR Signature (7 bytes) - used for detection/uninstall ---
tsr_sig:            db 'PC1PalT'

; --- Original interrupt vectors (far pointers: offset THEN segment) ---
orig_int10_ofs:     dw 0
orig_int10_seg:     dw 0
orig_int09_ofs:     dw 0
orig_int09_seg:     dw 0

; --- Adjustment state ---
adj_brightness:     db 0            ; signed: -3..+3 (each step = +/-8)
adj_vivid:          db 0            ; signed: -3..+3
adj_pop:            db 0            ; 0=off, 1=on (toggle)
palette_active:     db 1            ; 1=apply custom palette, 0=use defaults

; --- Random number generator seed ---
rng_seed:           dw 0

; --- Base palette: the original colors loaded from preset/file/cmdline.
;     Never modified by hotkeys. Adjustments are applied on top of this. ---
base_palette:
    db 0,  0,  0               ; color 0: Black
    db 0, 63, 63               ; color 1: Light Cyan (high intensity)
    db 63,  0, 63              ; color 2: Light Magenta (high intensity)
    db 63, 63, 63              ; color 3: White

; --- Active palette: recomputed from base + adjustments, written to HW ---
palette_rgb:
    db 0,  0,  0
    db 0, 63, 63
    db 63,  0, 63
    db 63, 63, 63

; --- 10 preset palettes (fallback + 1-9), resident for hotkey switching ---
res_preset_fallback:
    db 0,  0,  0,    0, 63, 63,   63,  0, 63,   63, 63, 63
res_preset_1:                       ; Arcade Vibrant
    db 0,  0,  0,    9, 27, 63,   63,  9,  9,   63, 45, 27
res_preset_2:                       ; Sierra Natural
    db 0,  0,  0,    9, 36, 36,   36, 18,  9,   63, 45, 36
res_preset_3:                       ; C64-inspired
    db 0,  0,  0,   18, 27, 63,   54, 27,  9,   63, 54, 36
res_preset_4:                       ; CGA Red/Green/White
    db 0,  0,  0,   63,  9,  9,    9, 63,  9,   63, 63, 63
res_preset_5:                       ; CGA Red/Blue/White
    db 0,  0,  0,   63,  0,  0,    0,  0, 63,   63, 63, 63
res_preset_6:                       ; Amstrad CPC
    db 0,  0,  0,    0, 42, 42,   42, 42,  0,   63, 63, 63
res_preset_7:                       ; Pastel
    db 0,  0,  0,   27, 36, 63,   63, 36, 45,   54, 54, 63
res_preset_8:                       ; Monochrome Amber
    db 0,  0,  0,   21, 14,  0,   42, 28,  0,   63, 42,  0
res_preset_9:                       ; Monochrome Green
    db 0,  0,  0,    0, 21,  0,    0, 42,  0,    0, 63,  0

; --- DAC entry -> user color index mapping (16 entries) ---
color_to_dac:
    db 0, 1, 1, 1, 2, 2, 3, 3, 2, 3, 1, 1, 2, 2, 3, 3

; --- Default CGA palette in V6355D format (16 x 2 bytes = 32 bytes) ---
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

; --- V6355D work buffers (resident) ---
user_colors:        times 8 db 0    ; 4 user colors x 2 bytes V6355D format
palette_buffer:     times 32 db 0   ; 16 colors x 2 bytes V6355D format

; --- Color tables for random palette generation ---

; CGA 15 non-black colors (6-bit RGB, for random generation)
cga_rgb_colors:
    db  0,  0, 42              ; Blue
    db  0, 42,  0              ; Green
    db  0, 42, 42              ; Cyan
    db 42,  0,  0              ; Red
    db 42,  0, 42              ; Magenta
    db 42, 21,  0              ; Brown
    db 42, 42, 42              ; Light Gray
    db 21, 21, 21              ; Dark Gray
    db 21, 21, 63              ; Light Blue
    db 21, 63, 21              ; Light Green
    db 21, 63, 63              ; Light Cyan
    db 63, 21, 21              ; Light Red
    db 63, 21, 63              ; Light Magenta
    db 63, 63, 21              ; Yellow
    db 63, 63, 63              ; White
CGA_RGB_COUNT       equ 15

; C64 palette (15 non-black, 6-bit RGB)
; Source: Lospec.com - Commodore 64 palette
c64_colors:
    db 63, 63, 63              ; White
    db 39, 19, 17              ; Red
    db 26, 47, 49              ; Cyan
    db 40, 21, 40              ; Purple
    db 23, 42, 23              ; Green
    db 20, 17, 38              ; Blue
    db 50, 52, 33              ; Yellow
    db 40, 26, 15              ; Orange
    db 27, 21,  4              ; Brown
    db 50, 31, 29              ; Light Red
    db 24, 24, 24              ; Dark Gray
    db 34, 34, 34              ; Medium Gray
    db 38, 56, 38              ; Light Green
    db 34, 31, 50              ; Light Blue
    db 43, 43, 43              ; Light Gray
C64_COUNT           equ 15

; Amstrad CPC hardware palette (26 non-black, 6-bit RGB)
; Source: Lospec.com - Amstrad CPC palette
cpc_colors:
    db  0,  0, 31              ; Dark Blue
    db  0,  0, 63              ; Bright Blue
    db  0, 32,  0              ; Dark Green
    db  0, 32, 32              ; Dark Cyan
    db  0, 32, 63              ; Sky Blue
    db  0, 63,  0              ; Bright Green
    db  0, 63, 32              ; Sea Green
    db  0, 63, 63              ; Bright Cyan
    db 32,  0,  0              ; Dark Red
    db 32,  0, 32              ; Dark Magenta
    db 31,  0, 63              ; Mauve
    db 32, 32,  0              ; Dark Yellow
    db 32, 32, 32              ; Gray
    db 32, 32, 63              ; Pastel Blue
    db 32, 63,  0              ; Lime
    db 32, 63, 32              ; Pastel Green
    db 32, 63, 63              ; Pastel Cyan
    db 63,  0,  0              ; Bright Red
    db 63,  0, 32              ; Purple
    db 63,  0, 63              ; Bright Magenta
    db 63, 31,  0              ; Orange
    db 63, 32, 32              ; Pastel Red
    db 63, 32, 63              ; Pastel Magenta
    db 63, 63,  0              ; Bright Yellow
    db 63, 63, 32              ; Pastel Yellow
    db 63, 63, 63              ; White
CPC_COUNT           equ 26

; ZX Spectrum palette (14 non-black, 6-bit RGB)
; Source: Lospec.com - ZX Spectrum palette
zx_colors:
    db  0,  0, 53              ; Blue
    db 53,  0,  0              ; Red
    db 53,  0, 53              ; Magenta
    db  0, 53,  0              ; Green
    db  0, 53, 53              ; Cyan
    db 53, 53,  0              ; Yellow
    db 53, 53, 53              ; White
    db  0,  0, 63              ; Bright Blue
    db 63,  0,  0              ; Bright Red
    db 63,  0, 63              ; Bright Magenta
    db  0, 63,  0              ; Bright Green
    db  0, 63, 63              ; Bright Cyan
    db 63, 63,  0              ; Bright Yellow
    db 63, 63, 63              ; Bright White
ZX_COUNT            equ 14

; ============================================================================
; INT 10h HOOK — Re-apply palette after CGA mode 4/5 set
; ============================================================================
tsr_int10:
    cmp ah, 0x00
    jne .chain
    cmp al, 0x04
    je .cga_mode
    cmp al, 0x05
    je .cga_mode

.chain:
    jmp far [cs:orig_int10_ofs]

.cga_mode:
    ; Let the original handler set the mode first
    pushf
    call far [cs:orig_int10_ofs]
    ; Re-apply custom palette if active
    cmp byte [cs:palette_active], 0
    je .no_apply
    call res_apply_palette
.no_apply:
    iret

; ============================================================================
; INT 09h HOOK — Ctrl+Alt-gated hotkeys for live palette adjustment
;
; Register preservation: AX, BP, SI, DS saved/restored.
; Keystroke acknowledgment (port 61h toggle) is done BEFORE calling any
; handler to free the keyboard controller early. This prevents keyboard
; lockup on the NEC V40 when handlers take long (e.g. random palette
; generation + V6355D DAC write). EOI is sent to the PIC in .swallow.
; ============================================================================
tsr_int09:
    push ax
    push bp
    push si
    push ds

    ; Read scan code from keyboard controller
    in al, 0x60

    ; Ignore key releases (bit 7 set)
    test al, 0x80
    jnz .chain_kb

    ; Check if both Ctrl and Alt are held (BIOS keyboard flags)
    push ax
    mov ax, 0x0040
    mov ds, ax
    mov al, [0x0017]
    and al, CTRLALT_BITS
    cmp al, CTRLALT_BITS
    pop ax
    jne .chain_kb              ; Ctrl+Alt not both held -> pass through

    ; Ctrl+Alt held — check for our hotkeys
    mov ah, al                 ; save scan code in AH

    ; Preset keys 1-9
    cmp ah, SCAN_1
    jb .check_special
    cmp ah, SCAN_9
    ja .check_special
    ; AH = 02h..0Ah -> preset 1..9
    sub ah, SCAN_1             ; AH = 0..8 = preset index
    call .ack_keystroke        ; acknowledge BEFORE heavy processing
    call hotkey_load_preset
    jmp .swallow

.check_special:
    cmp ah, SCAN_P
    je .do_pop
    cmp ah, SCAN_R
    je .do_reset
    cmp ah, SCAN_UP
    je .do_bright_up
    cmp ah, SCAN_DOWN
    je .do_bright_dn
    cmp ah, SCAN_RIGHT
    je .do_vivid_up
    cmp ah, SCAN_LEFT
    je .do_vivid_dn
    cmp ah, SCAN_SPACE
    je .do_random
    cmp ah, SCAN_C
    je .do_random_c64
    cmp ah, SCAN_A
    je .do_random_cpc
    cmp ah, SCAN_Z
    je .do_random_zx
    jmp .chain_kb              ; not our key -> pass through

.do_pop:
    call .ack_keystroke
    xor byte [cs:adj_pop], 1  ; toggle 0<->1
    call recompute_and_apply
    jmp .swallow

.do_reset:
    call .ack_keystroke
    call hotkey_load_fallback
    jmp .swallow

.do_bright_up:
    cmp byte [cs:adj_brightness], MAX_BRIGHT_LEVEL
    jge .swallow_ack           ; already at max
    call .ack_keystroke
    inc byte [cs:adj_brightness]
    call recompute_and_apply
    jmp .swallow

.do_bright_dn:
    cmp byte [cs:adj_brightness], -MAX_BRIGHT_LEVEL
    jle .swallow_ack           ; already at min
    call .ack_keystroke
    dec byte [cs:adj_brightness]
    call recompute_and_apply
    jmp .swallow

.do_vivid_up:
    cmp byte [cs:adj_vivid], MAX_VIVID_LEVEL
    jge .swallow_ack
    call .ack_keystroke
    inc byte [cs:adj_vivid]
    call recompute_and_apply
    jmp .swallow

.do_vivid_dn:
    cmp byte [cs:adj_vivid], -MAX_VIVID_LEVEL
    jle .swallow_ack
    call .ack_keystroke
    dec byte [cs:adj_vivid]
    call recompute_and_apply
    jmp .swallow

.do_random:
    call .ack_keystroke
    mov si, cga_rgb_colors
    mov bp, CGA_RGB_COUNT
    call hotkey_random
    jmp .swallow

.do_random_c64:
    call .ack_keystroke
    mov si, c64_colors
    mov bp, C64_COUNT
    call hotkey_random
    jmp .swallow

.do_random_cpc:
    call .ack_keystroke
    mov si, cpc_colors
    mov bp, CPC_COUNT
    call hotkey_random
    jmp .swallow

.do_random_zx:
    call .ack_keystroke
    mov si, zx_colors
    mov bp, ZX_COUNT
    call hotkey_random
    jmp .swallow

; --- Acknowledge keystroke via port 61h (frees keyboard controller) ---
.ack_keystroke:
    push ax
    in al, 0x61
    or al, 0x80
    out 0x61, al
    and al, 0x7F
    out 0x61, al
    pop ax
    ret

; --- Swallow path when acknowledge already done (e.g. at-limit checks) ---
.swallow_ack:
    call .ack_keystroke
    ; fall through to .swallow

.swallow:
    ; Send EOI to PIC (keystroke already acknowledged above)
    mov al, 0x20
    out 0x20, al
    pop ds
    pop si
    pop bp
    pop ax
    iret

.chain_kb:
    pop ds
    pop si
    pop bp
    pop ax
    jmp far [cs:orig_int09_ofs]

; ============================================================================
; hotkey_load_preset — Load preset by index (AH = 0..8)
; Resets adjustments and recomputes.
; ============================================================================
hotkey_load_preset:
    pusha
    push es

    push cs
    pop es

    ; Calculate source: res_preset_1 + AH * 12
    mov al, ah
    xor ah, ah
    mov cl, 12
    mul cl                     ; AX = preset_index * 12
    mov si, res_preset_1
    add si, ax

    ; Copy 12 bytes to base_palette
    mov di, base_palette
    mov cx, 12
.copy:
    mov al, [cs:si]
    mov [cs:di], al
    inc si
    inc di
    loop .copy

    ; Reset adjustments
    mov byte [cs:adj_brightness], 0
    mov byte [cs:adj_vivid], 0
    mov byte [cs:adj_pop], 0

    pop es
    popa
    call recompute_and_apply
    ret

; ============================================================================
; hotkey_load_fallback — Reset to default CGA palette
; In CGA mode 4/5: applies standard high-intensity CGA through our routing.
; In text mode: restores full 16-color DAC and goes dormant.
; ============================================================================
hotkey_load_fallback:
    pusha
    push es

    push cs
    pop es

    mov si, res_preset_fallback
    mov di, base_palette
    mov cx, 12
.copy:
    mov al, [cs:si]
    mov [cs:di], al
    inc si
    inc di
    loop .copy

    mov byte [cs:adj_brightness], 0
    mov byte [cs:adj_vivid], 0
    mov byte [cs:adj_pop], 0

    pop es
    popa

    ; Check current video mode to decide reset strategy
    push ax
    push ds
    mov ax, 0x0040
    mov ds, ax
    mov al, [0x0049]           ; BIOS current video mode
    pop ds
    cmp al, 4
    je .cga_mode_reset
    cmp al, 5
    je .cga_mode_reset

    ; Text mode: full V6355D restore, go dormant
    mov byte [cs:palette_active], 0
    pop ax
    call res_restore_default
    ret

.cga_mode_reset:
    ; CGA mode: apply standard CGA through our routing
    mov byte [cs:palette_active], 1
    pop ax
    call recompute_and_apply
    ret

; ============================================================================
; recompute_and_apply — Rebuild palette_rgb from base + adjustments, then
;                       convert to V6355D format and write to hardware.
;
; Pipeline:  base -> copy to palette_rgb
;            -> apply vivid (N times boost or mute)
;            -> if pop: saturation_boost + contrast_boost
;            -> apply brightness (N x +/-8, clamped)
;            -> convert to V6355D and write to DAC
; ============================================================================
recompute_and_apply:
    pusha
    push ds
    push es

    push cs
    pop ds
    push cs
    pop es

    mov byte [palette_active], 1

    ; Step 1: Copy base_palette -> palette_rgb
    mov si, base_palette
    mov di, palette_rgb
    mov cx, 12
    cld
    rep movsb

    ; Step 2: Vivid adjustment (-3..+3 steps of saturation boost/mute)
    mov al, [adj_vivid]
    test al, al
    jz .rc_pop_check
    js .rc_vivid_mute
    ; Positive: apply saturation boost N times
    mov cl, al
    xor ch, ch
.rc_vivid_boost_loop:
    call res_saturation_boost
    loop .rc_vivid_boost_loop
    jmp .rc_pop_check
.rc_vivid_mute:
    ; Negative: apply saturation mute N times
    neg al
    mov cl, al
    xor ch, ch
.rc_vivid_mute_loop:
    call res_saturation_mute
    loop .rc_vivid_mute_loop

.rc_pop_check:
    ; Step 3: Pop = saturation boost + contrast boost
    cmp byte [adj_pop], 0
    je .rc_brightness
    call res_saturation_boost
    call res_contrast_boost

.rc_brightness:
    ; Step 4: Brightness (-3..+3 steps, each step = +/-8)
    mov al, [adj_brightness]
    test al, al
    jz .rc_apply
    js .rc_dim
    ; Positive: brighten
    mov cl, al
    xor ch, ch
.rc_bright_loop:
    call res_brighten
    loop .rc_bright_loop
    jmp .rc_apply
.rc_dim:
    neg al
    mov cl, al
    xor ch, ch
.rc_dim_loop:
    call res_dim
    loop .rc_dim_loop

.rc_apply:
    ; Step 5: Convert and write to V6355D
    call res_apply_palette

    pop es
    pop ds
    popa
    ret

; ============================================================================
; res_apply_palette — Convert palette_rgb to V6355D format and write to DAC.
; Uses color_to_dac[] mapping for conflict-free CGA palette routing.
; ============================================================================
res_apply_palette:
    pusha
    push ds
    push es

    push cs
    pop ds
    push cs
    pop es
    cld                         ; Ensure forward direction for lodsb/stosb

    ; Step 1: Convert 4 RGB colors (6-bit) to V6355D format in user_colors
    mov si, palette_rgb
    mov di, user_colors
    mov cx, 4
.convert:
    lodsb                       ; Red (0-63)
    shr al, 3                  ; Scale to 0-7
    and al, 0x07
    mov bl, al
    lodsb                       ; Green (0-63)
    shr al, 3
    shl al, 4                  ; Green -> bits 4-6
    mov bh, al
    lodsb                       ; Blue (0-63)
    shr al, 3
    and al, 0x07
    or bh, al                  ; Blue -> bits 0-2
    mov al, bl
    stosb                       ; Byte 1: Red
    mov al, bh
    stosb                       ; Byte 2: Green|Blue
    loop .convert

    ; Step 2: Build 32-byte palette_buffer via color_to_dac mapping
    mov si, color_to_dac
    mov di, palette_buffer
    mov cx, 16
.build:
    lodsb                       ; AL = user color index (0-3)
    xor ah, ah
    shl al, 1                  ; x 2 bytes per V6355D color
    mov bx, ax
    mov ax, [user_colors + bx] ; 2 bytes of V6355D data
    stosw
    loop .build

    ; Step 3: Write to V6355D DAC
    call res_write_palette_to_dac

    pop es
    pop ds
    popa
    ret

; ============================================================================
; res_write_palette_to_dac — Write palette_buffer (32 bytes) to V6355D
; Uses pushf/cli/popf to disable interrupts during the DAC write sequence
; without unconditionally re-enabling them (safe to call from ISR context).
; ============================================================================
res_write_palette_to_dac:
    pusha
    push ds
    pushf                       ; Save caller's interrupt state
    push cs
    pop ds
    cld                         ; Ensure forward direction for lodsb

    cli

    mov al, PAL_WRITE_EN
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2
    jmp short $+2

    mov si, palette_buffer
    mov cx, FULL_PALETTE * 2    ; 32 bytes
    mov dx, PORT_REG_DATA
.write:
    lodsb
    out dx, al
    jmp short $+2
    loop .write

    jmp short $+2
    mov al, PAL_WRITE_DIS
    mov dx, PORT_REG_ADDR
    out dx, al
    jmp short $+2

    popf                        ; Restore caller's interrupt state

    pop ds
    popa
    ret

; ============================================================================
; res_restore_default — Write standard CGA palette to V6355D DAC
; ============================================================================
res_restore_default:
    pusha
    push ds
    push es
    push cs
    pop ds
    push cs
    pop es

    ; Copy CGA defaults to palette_buffer
    mov si, cga_full_palette
    mov di, palette_buffer
    mov cx, 32
    cld
    rep movsb

    call res_write_palette_to_dac

    pop es
    pop ds
    popa
    ret

; ============================================================================
; RESIDENT ADJUSTMENT ROUTINES
; These operate on palette_rgb (colors 1-3 only, skip background at offset 0).
; Assume DS=CS (set by recompute_and_apply before calling).
; ============================================================================

; --- res_brighten: Add 8 to each RGB channel, clamp at 63 ---
res_brighten:
    push cx
    push si
    mov si, palette_rgb + 3    ; skip color 0
    mov cx, 9
.loop:
    mov al, [si]
    add al, 8
    cmp al, 63
    jbe .ok
    mov al, 63
.ok:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

; --- res_dim: Subtract 8 from each RGB channel, clamp at 0 ---
res_dim:
    push cx
    push si
    mov si, palette_rgb + 3
    mov cx, 9
.loop:
    mov al, [si]
    sub al, 8
    jnc .ok
    xor al, al
.ok:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

; --- res_saturation_boost: ch + (ch - gray) / 2, clamp 0-63 ---
res_saturation_boost:
    push bx
    push cx
    push si
    mov si, palette_rgb + 3
    mov cx, 3                  ; 3 color triples
.color:
    xor ax, ax
    mov al, [si]
    add al, [si+1]
    add al, [si+2]            ; AL = R+G+B
    mov bl, 3
    div bl                     ; AL = gray
    mov bl, al                 ; BL = gray

    push cx
    mov cx, 3
.ch:
    mov al, [si]
    sub al, bl                 ; AL = ch - gray (signed)
    sar al, 1                  ; AL = (ch - gray) / 2
    add al, [si]              ; AL = ch + (ch - gray) / 2
    test al, al
    jns .not_neg
    xor al, al
    jmp .store
.not_neg:
    cmp al, 63
    jbe .store
    mov al, 63
.store:
    mov [si], al
    inc si
    loop .ch
    pop cx
    loop .color
    pop si
    pop cx
    pop bx
    ret

; --- res_saturation_mute: (ch + gray) / 2 ---
res_saturation_mute:
    push bx
    push cx
    push si
    mov si, palette_rgb + 3
    mov cx, 3
.color:
    xor ax, ax
    mov al, [si]
    add al, [si+1]
    add al, [si+2]
    mov bl, 3
    div bl
    mov bl, al                 ; BL = gray

    push cx
    mov cx, 3
.ch:
    mov al, [si]
    add al, bl
    shr al, 1                 ; (ch + gray) / 2
    mov [si], al
    inc si
    loop .ch
    pop cx
    loop .color
    pop si
    pop cx
    pop bx
    ret

; --- res_contrast_boost: ch + (ch - 31) / 2, clamp 0-63 ---
res_contrast_boost:
    push cx
    push si
    mov si, palette_rgb + 3
    mov cx, 9
.loop:
    mov al, [si]
    sub al, 31                 ; signed
    sar al, 1
    add al, [si]
    test al, al
    jns .not_neg
    xor al, al
    jmp .store
.not_neg:
    cmp al, 63
    jbe .store
    mov al, 63
.store:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

; ============================================================================
; hotkey_random — Pick 3 unique random colors from a palette table
; Input: SI = color table (N entries x 3 bytes), BP = color count
;
; Sets DS=CS and ES=CS for safe access to resident data. Reads the BIOS
; timer tick (0040:006C) via a temporary ES=0x0040 to seed the RNG.
; Picks 3 distinct colors from the table and writes them to base_palette.
; ============================================================================
hotkey_random:
    pusha
    push ds
    push es

    ; DS = CS for all resident data access (same pattern as hotkey_load_preset)
    push cs
    pop ds
    push cs
    pop es

    ; Save table pointer in DI
    mov di, si

    ; Seed from BIOS timer tick (read via ES, keep DS=CS)
    push es
    mov ax, 0x0040
    mov es, ax
    mov ax, [es:0x006C]
    pop es
    add [rng_seed], ax

    ; Pick color 1
    mov bx, bp
    call get_random_n
    mov cl, dl                  ; CL = index1
    mov si, di
    add si, bx
    mov al, [si]
    mov [base_palette+3], al
    mov al, [si+1]
    mov [base_palette+4], al
    mov al, [si+2]
    mov [base_palette+5], al

    ; Pick color 2 (must differ from color 1)
.pick2:
    mov bx, bp
    call get_random_n
    cmp dl, cl
    je .pick2
    mov ch, dl                  ; CH = index2
    mov si, di
    add si, bx
    mov al, [si]
    mov [base_palette+6], al
    mov al, [si+1]
    mov [base_palette+7], al
    mov al, [si+2]
    mov [base_palette+8], al

    ; Pick color 3 (must differ from color 1 and 2)
.pick3:
    mov bx, bp
    call get_random_n
    cmp dl, cl
    je .pick3
    cmp dl, ch
    je .pick3
    mov si, di
    add si, bx
    mov al, [si]
    mov [base_palette+9], al
    mov al, [si+1]
    mov [base_palette+10], al
    mov al, [si+2]
    mov [base_palette+11], al

    ; Reset adjustments, activate palette
    mov byte [adj_brightness], 0
    mov byte [adj_vivid], 0
    mov byte [adj_pop], 0

    pop es
    pop ds
    popa
    call recompute_and_apply
    ret

; ============================================================================
; get_random_n — Return random index into N-color table
; Input: BX = color count (modulus N)
; Output: BX = (0..N-1) * 3  (byte offset), DL = raw index (0..N-1)
; Trashes: AX, DX
; ============================================================================
get_random_n:
    push cx
    mov cx, bx                  ; save count
    mov ax, [cs:rng_seed]
    mov bx, 25173
    mul bx                      ; DX:AX = seed * 25173
    add ax, 13849
    mov [cs:rng_seed], ax       ; store new seed
    xor dx, dx
    mov bx, cx                  ; BX = count
    div bx                      ; DX = remainder 0..N-1
    mov bx, dx
    mov ax, bx
    shl bx, 1
    add bx, ax                  ; BX = index * 3
    pop cx
    ret

; ============================================================================
; End of resident section
; ============================================================================
tsr_end:

; ============================================================================
; =====================  TRANSIENT SECTION  ==================================
; ============================================================================
; Everything below is discarded after going TSR.
; ============================================================================

; ============================================================================
; Main installer entry point
; ============================================================================
main:
    mov dx, msg_banner
    call print_string

    ; Check for /U (uninstall) first
    call check_uninstall
    cmp al, 1
    je .do_uninstall

    ; Parse all command-line switches
    call check_switches
    push ax                    ; save switch result
    call parse_bg_color
    call parse_fg_colors
    pop ax
    cmp byte [parse_error], 0
    jne .exit_no_tsr
    cmp al, 1
    je .show_help
    cmp al, 2
    je .do_reset_install
    cmp al, 3
    je .preset_1
    cmp al, 4
    je .preset_2
    cmp al, 5
    je .preset_3
    cmp al, 6
    je .preset_4
    cmp al, 7
    je .preset_5
    cmp al, 8
    je .preset_6
    cmp al, 9
    je .preset_7
    cmp al, 10
    je .preset_8
    cmp al, 11
    je .preset_9
    jmp .load_file

.show_help:
    mov dx, msg_help
    call print_string
    mov dx, msg_pause
    call print_string
.flush_kb:
    mov ah, 0x01
    int 0x16
    jz .wait_key
    mov ah, 0x00
    int 0x16
    jmp .flush_kb
.wait_key:
    mov ah, 0x00
    int 0x16
    mov dx, msg_help2
    call print_string
    jmp .exit_no_tsr

.do_reset_install:
    mov dx, msg_resetting
    call print_string
    mov si, res_preset_fallback
    mov byte [is_default_install], 1
    jmp .apply_preset

.preset_1:
    mov dx, msg_preset1
    call print_string
    mov si, res_preset_1
    jmp .apply_preset
.preset_2:
    mov dx, msg_preset2
    call print_string
    mov si, res_preset_2
    jmp .apply_preset
.preset_3:
    mov dx, msg_preset3
    call print_string
    mov si, res_preset_3
    jmp .apply_preset
.preset_4:
    mov dx, msg_preset4
    call print_string
    mov si, res_preset_4
    jmp .apply_preset
.preset_5:
    mov dx, msg_preset5
    call print_string
    mov si, res_preset_5
    jmp .apply_preset
.preset_6:
    mov dx, msg_preset6
    call print_string
    mov si, res_preset_6
    jmp .apply_preset
.preset_7:
    mov dx, msg_preset7
    call print_string
    mov si, res_preset_7
    jmp .apply_preset
.preset_8:
    mov dx, msg_preset8
    call print_string
    mov si, res_preset_8
    jmp .apply_preset
.preset_9:
    mov dx, msg_preset9
    call print_string
    mov si, res_preset_9
    jmp .apply_preset

.apply_preset:
    ; Copy 12 bytes from preset to config_buffer
    mov di, config_buffer
    mov cx, 12
    cld
    rep movsb
    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    jmp .do_install

.load_file:
    call load_config
    jc .use_fallback
    call validate_palette
    jc .use_fallback

    ; If file had multiple palettes, copy them over resident presets
    cmp byte [palettes_loaded], 1
    jbe .single_palette
    call copy_file_palettes_to_presets
    mov dx, msg_multi_loaded
    call print_string
.single_palette:
    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    jmp .do_install

.use_fallback:
    ; Only show message if user explicitly specified a file
    cmp byte [explicit_file], 1
    jne .skip_fallback_msg
    mov dx, msg_fallback
    call print_string
.skip_fallback_msg:
    call load_fallback_to_config
    call apply_bg_override
    call apply_fg_override
    call apply_adjustments
    ; Default install if no customization flags set
    cmp byte [bg_specified], 0
    jne .do_install
    cmp byte [fg_specified], 0
    jne .do_install
    cmp byte [pop_flag_cmd], 0
    jne .do_install
    cmp byte [brightness_adj_cmd], 0
    jne .do_install
    cmp byte [vivid_adj_cmd], 0
    jne .do_install
    mov byte [is_default_install], 1

.do_install:
    ; Copy final config_buffer -> base_palette AND palette_rgb
    mov si, config_buffer
    mov di, base_palette
    mov cx, 12
    cld
    rep movsb
    mov si, config_buffer
    mov di, palette_rgb
    mov cx, 12
    cld
    rep movsb

    ; Reset adjustment state
    mov byte [adj_brightness], 0
    mov byte [adj_vivid], 0
    mov byte [adj_pop], 0

    ; Check if this is a default install (no custom palette)
    cmp byte [is_default_install], 0
    jne .skip_hw_apply

    ; Apply palette now (before printing preview so colors are visible)
    mov byte [palette_active], 1
    call res_apply_palette
    jmp .palette_applied

.skip_hw_apply:
    ; Default install: don't touch hardware, let INT 10h hook handle it
    mov byte [palette_active], 0

.palette_applied:
    ; Print loaded colors
    call print_colors

.check_installed:
    call check_already_loaded
    cmp al, 1
    je .already_loaded

    ; Save original INT 10h
    mov ax, 0x3510
    int 0x21
    mov [orig_int10_seg], es
    mov [orig_int10_ofs], bx

    ; Save original INT 09h
    mov ax, 0x3509
    int 0x21
    mov [orig_int09_seg], es
    mov [orig_int09_ofs], bx

    ; Install INT 10h hook
    mov ax, 0x2510
    mov dx, tsr_int10
    int 0x21

    ; Install INT 09h hook
    mov ax, 0x2509
    mov dx, tsr_int09
    int 0x21

    mov dx, msg_installed
    call print_string

    ; Go resident — compute size in paragraphs
    mov dx, tsr_end
    add dx, 15
    shr dx, 4
    mov ax, 0x3100
    int 0x21

.already_loaded:
    ; TSR is already resident — update its data via the resident segment.
    ; Get resident segment from INT 10h vector (ES = resident code segment)
    mov ax, 0x3510
    int 0x21
    ; ES now points to the resident TSR segment

    ; Copy base_palette to resident
    push ds
    push cs
    pop ds
    mov si, base_palette
    mov di, base_palette
    mov cx, 12
    cld
    rep movsb

    ; Copy palette_rgb to resident
    mov si, palette_rgb
    mov di, palette_rgb
    mov cx, 12
    cld
    rep movsb

    ; Copy adjustments to resident
    mov al, [adj_brightness]
    mov [es:adj_brightness], al
    mov al, [adj_vivid]
    mov [es:adj_vivid], al
    mov al, [adj_pop]
    mov [es:adj_pop], al
    mov al, [palette_active]
    mov [es:palette_active], al
    pop ds

    ; If multi-palette file was loaded, copy presets to resident
    cmp byte [palettes_loaded], 1
    jbe .no_preset_update
    push ds
    push cs
    pop ds
    mov si, res_preset_1
    mov di, res_preset_1
    mov al, [palettes_loaded]
    xor ah, ah
    mov cl, 12
    mul cl
    mov cx, ax
    cld
    rep movsb
    pop ds
.no_preset_update:

    ; If default install (/R), restore built-in presets and default palette
    cmp byte [is_default_install], 0
    je .reload_done
    ; Copy all 9 original built-in presets from transient -> resident
    push ds
    push cs
    pop ds
    mov si, res_preset_1
    mov di, res_preset_1
    mov cx, 9 * 12             ; 9 presets x 12 bytes each
    cld
    rep movsb
    pop ds
    call res_restore_default
.reload_done:

    mov dx, msg_already_loaded
    call print_string
    jmp .exit_no_tsr

.do_uninstall:
    call uninstall_tsr
    jmp .exit_no_tsr

.exit_no_tsr:
    mov ax, 0x4C00
    int 0x21

; ============================================================================
; check_already_loaded — AL=1 if TSR signature found at INT 10h handler
; ============================================================================
check_already_loaded:
    push bx
    push cx
    push si
    push di
    push es

    ; Get current INT 10h vector
    mov ax, 0x3510
    int 0x21
    ; ES:BX -> current INT 10h handler
    ; Check if our signature exists at the known offset in that segment
    mov di, tsr_sig             ; offset of signature in our code
    mov si, tsr_sig             ; compare against our own copy
    mov cx, 7
    push ds
    push cs
    pop ds                     ; DS:SI = CS:tsr_sig
    repe cmpsb                 ; compare ES:DI vs DS:SI
    pop ds
    jne .not_loaded

    mov al, 1
    jmp .cal_done

.not_loaded:
    xor al, al

.cal_done:
    pop es
    pop di
    pop si
    pop cx
    pop bx
    ret

; ============================================================================
; uninstall_tsr — Restore original INT 09h + INT 10h, free TSR memory
; ============================================================================
uninstall_tsr:
    push ax
    push bx
    push dx
    push ds
    push es

    ; Get current INT 10h vector to find our TSR segment
    mov ax, 0x3510
    int 0x21
    ; ES:BX -> current handler; verify signature
    mov di, tsr_sig
    mov si, tsr_sig
    mov cx, 7
    push ds
    push cs
    pop ds
    repe cmpsb
    pop ds
    jne .not_us

    ; ES = TSR segment. Restore original INT 10h from TSR's saved values.
    mov ax, 0x2510
    push word [es:orig_int10_seg]
    pop ds
    mov dx, [es:orig_int10_ofs]
    int 0x21

    ; Restore original INT 09h
    push cs
    pop ds                     ; restore DS for later
    mov ax, 0x2509
    push word [es:orig_int09_seg]
    pop ds
    mov dx, [es:orig_int09_ofs]
    int 0x21

    ; Free TSR's environment block first (segment at PSP offset 2Ch)
    push es
    mov ax, [es:0x2C]          ; environment segment from PSP
    or ax, ax
    jz .no_env
    mov es, ax
    mov ah, 0x49
    int 0x21
.no_env:
    pop es

    ; Free TSR memory block (ES = TSR PSP segment)
    mov ah, 0x49
    int 0x21

    push cs
    pop ds                     ; ensure DS = CS for print_string

    mov dx, msg_unloaded
    jmp .ui_msg

.not_us:
    push cs
    pop ds
    mov dx, msg_unload_error

.ui_msg:
    call print_string

    pop es
    pop ds
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; check_uninstall — AL=1 if /U found on command line
; ============================================================================
check_uninstall:
    push si
    mov si, 0x81
.skip:
    lodsb
    cmp al, ' '
    je .skip
    cmp al, 0x0D
    je .none
    cmp al, '/'
    je .slash
    cmp al, '-'
    je .slash
    jmp .none
.slash:
    lodsb
    cmp al, 'U'
    je .yes
    cmp al, 'u'
    je .yes
.none:
    xor al, al
    jmp .done
.yes:
    mov al, 1
.done:
    pop si
    ret

; ============================================================================
; check_switches — Multi-pass scanner. Returns AL:
;   0=none/file, 1=help, 2=reset, 3-11=presets 1-9
; Also sets [brightness_adj_cmd], [vivid_adj_cmd], [pop_flag_cmd] from modifiers.
; ============================================================================
check_switches:
    push si
    mov si, 0x81

.skip_spaces:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_switch

    cmp al, '/'
    je .check_char
    cmp al, '-'
    je .check_char
    jmp .no_switch

.check_char:
    lodsb
    cmp al, '?'
    je .is_help
    cmp al, 'H'
    je .is_help
    cmp al, 'h'
    je .is_help
    cmp al, 'R'
    je .is_reset
    cmp al, 'r'
    je .is_reset
    cmp al, 'U'
    je .skip_token              ; /U handled separately
    cmp al, 'u'
    je .skip_token
    cmp al, 'b'
    je .skip_bg_switch
    cmp al, 'B'
    je .skip_bg_switch
    cmp al, 'c'
    je .skip_c_switch
    cmp al, 'C'
    je .skip_c_switch
    cmp al, 'd'
    je .parse_dim_switch
    cmp al, 'D'
    je .parse_dim_switch
    cmp al, 'v'
    je .parse_vivid_switch
    cmp al, 'V'
    je .parse_vivid_switch
    cmp al, 'p'
    je .is_pop
    cmp al, 'P'
    je .is_pop
    cmp al, '1'
    je .is_preset1
    cmp al, '2'
    je .is_preset2
    cmp al, '3'
    je .is_preset3
    cmp al, '4'
    je .is_preset4
    cmp al, '5'
    je .is_preset5
    cmp al, '6'
    je .is_preset6
    cmp al, '7'
    je .is_preset7
    cmp al, '8'
    je .is_preset8
    cmp al, '9'
    je .is_preset9
    jmp .bad_switch

.skip_token:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_switch
    jmp .skip_token

.skip_bg_switch:
.skip_c_switch:
    lodsb
    cmp al, ':'
    jne .bad_switch
.skip_switch_arg:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_switch
    jmp .skip_switch_arg

.parse_dim_switch:
    lodsb
    cmp al, ':'
    jne .bad_switch
    lodsb
    cmp al, '+'
    je .dim_plus
    cmp al, '-'
    je .dim_minus
    jmp .bad_switch
.dim_plus:
    mov byte [brightness_adj_cmd], 1
    jmp .after_modifier
.dim_minus:
    mov byte [brightness_adj_cmd], 2
    jmp .after_modifier

.parse_vivid_switch:
    lodsb
    cmp al, ':'
    jne .bad_switch
    lodsb
    cmp al, '+'
    je .vivid_plus
    cmp al, '-'
    je .vivid_minus
    jmp .bad_switch
.vivid_plus:
    mov byte [vivid_adj_cmd], 1
    jmp .after_modifier
.vivid_minus:
    mov byte [vivid_adj_cmd], 2
    jmp .after_modifier

.is_pop:
    mov byte [pop_flag_cmd], 1

.after_modifier:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_switch
    dec si
    jmp .skip_spaces

.is_help:     mov byte [switch_result], 1
    jmp .sw_done
.is_reset:    mov byte [switch_result], 2
    jmp .sw_done
.is_preset1:  mov byte [switch_result], 3
    jmp .after_modifier
.is_preset2:  mov byte [switch_result], 4
    jmp .after_modifier
.is_preset3:  mov byte [switch_result], 5
    jmp .after_modifier
.is_preset4:  mov byte [switch_result], 6
    jmp .after_modifier
.is_preset5:  mov byte [switch_result], 7
    jmp .after_modifier
.is_preset6:  mov byte [switch_result], 8
    jmp .after_modifier
.is_preset7:  mov byte [switch_result], 9
    jmp .after_modifier
.is_preset8:  mov byte [switch_result], 10
    jmp .after_modifier
.is_preset9:  mov byte [switch_result], 11
    jmp .after_modifier

.bad_switch:
    mov dx, msg_bad_switch
    call print_string
    mov byte [parse_error], 1
    xor al, al
    jmp .sw_done

.no_switch:
.sw_done:
    mov al, [switch_result]
    pop si
    ret

; ============================================================================
; parse_bg_color — Scan for /b:colorname, set bg_specified + bg_color
; ============================================================================
parse_bg_color:
    push si
    push di
    push cx
    push bx

    mov byte [bg_specified], 0
    xor ch, ch
    mov cl, [0x80]
    or cx, cx
    jz .pb_done
    mov si, 0x81

.pb_scan:
    cmp cx, 0
    je .pb_done
    lodsb
    dec cx
    cmp al, '/'
    je .pb_check_b
    cmp al, '-'
    je .pb_check_b
    jmp .pb_scan

.pb_check_b:
    cmp cx, 2
    jb .pb_done
    lodsb
    dec cx
    or al, 0x20                ; lowercase
    cmp al, 'b'
    jne .pb_scan
    lodsb
    dec cx
    cmp al, ':'
    jne .pb_scan

    ; Try matching each entry in bg_color_names
    mov bx, bg_color_names

.pb_try_entry:
    cmp byte [bx], 0           ; end of table?
    je .pb_not_found
    push si
    push cx

.pb_match_char:
    cmp byte [bx], 0           ; end of name string?
    je .pb_check_end
    cmp cx, 0
    je .pb_no_match_pop
    lodsb
    dec cx
    or al, 0x20                ; case-insensitive
    cmp al, [bx]
    jne .pb_no_match_pop
    inc bx
    jmp .pb_match_char

.pb_check_end:
    ; Name matched. Check delimiter (space, CR, or end of buffer)
    cmp cx, 0
    je .pb_found
    mov al, [si]
    cmp al, ' '
    je .pb_found
    cmp al, 0x0D
    je .pb_found

.pb_no_match_pop:
    pop cx
    pop si
    ; Skip to end of this table entry (past null + 3 RGB bytes)
.pb_skip_name:
    cmp byte [bx], 0
    je .pb_skip_rgb
    inc bx
    jmp .pb_skip_name
.pb_skip_rgb:
    inc bx                     ; skip null terminator
    add bx, 3                  ; skip RGB bytes
    jmp .pb_try_entry

.pb_found:
    pop cx                     ; discard saved cx
    pop cx                     ; discard saved si
    inc bx                     ; skip null terminator
    mov al, [bx]
    mov [bg_color], al
    mov al, [bx+1]
    mov [bg_color+1], al
    mov al, [bx+2]
    mov [bg_color+2], al
    mov byte [bg_specified], 1
    jmp .pb_done

.pb_not_found:
    mov dx, msg_bad_bg
    call print_string
    mov byte [parse_error], 1

.pb_done:
    pop bx
    pop cx
    pop di
    pop si
    ret

; ============================================================================
; parse_fg_colors — Scan for /c:name1,name2,name3
; ============================================================================
parse_fg_colors:
    push si
    push di
    push cx
    push bx

    mov byte [fg_specified], 0
    xor ch, ch
    mov cl, [0x80]
    or cx, cx
    jz .pf_done
    mov si, 0x81

.pf_scan:
    cmp cx, 0
    je .pf_done
    lodsb
    dec cx
    cmp al, '/'
    je .pf_check_c
    cmp al, '-'
    je .pf_check_c
    jmp .pf_scan

.pf_check_c:
    cmp cx, 2
    jb .pf_done
    lodsb
    dec cx
    or al, 0x20
    cmp al, 'c'
    jne .pf_scan
    lodsb
    dec cx
    cmp al, ':'
    jne .pf_scan

    mov di, fg_colors
    mov byte [fg_count], 0

.pf_next_color:
    call .pf_lookup_color
    jc .pf_error
    add di, 3
    inc byte [fg_count]
    cmp byte [fg_count], 3
    je .pf_all_found
    cmp cx, 0
    je .pf_error
    lodsb
    dec cx
    cmp al, ','
    jne .pf_error
    jmp .pf_next_color

.pf_all_found:
    mov byte [fg_specified], 1
    jmp .pf_done

.pf_error:
    mov dx, msg_bad_fg
    call print_string
    mov byte [parse_error], 1

.pf_done:
    pop bx
    pop cx
    pop di
    pop si
    ret

; --- Internal: look up one color name at SI, write RGB to [DI] ---
.pf_lookup_color:
    mov bx, bg_color_names

.pf_try_entry:
    cmp byte [bx], 0
    je .pf_not_found
    push si
    push cx

.pf_match_char:
    cmp byte [bx], 0           ; end of name?
    je .pf_check_delim
    cmp cx, 0
    je .pf_no_match_pop
    lodsb
    dec cx
    or al, 0x20
    cmp al, [bx]
    jne .pf_no_match_pop
    inc bx
    jmp .pf_match_char

.pf_check_delim:
    cmp cx, 0
    je .pf_color_found
    mov al, [si]
    cmp al, ','
    je .pf_color_found
    cmp al, ' '
    je .pf_color_found
    cmp al, 0x0D
    je .pf_color_found

.pf_no_match_pop:
    pop cx
    pop si
.pf_skip_entry:
    cmp byte [bx], 0
    je .pf_skip_entry_rgb
    inc bx
    jmp .pf_skip_entry
.pf_skip_entry_rgb:
    inc bx
    add bx, 3
    jmp .pf_try_entry

.pf_color_found:
    pop cx                     ; discard saved cx
    pop cx                     ; discard saved si
    inc bx                     ; skip null terminator
    mov al, [bx]
    mov [di], al
    mov al, [bx+1]
    mov [di+1], al
    mov al, [bx+2]
    mov [di+2], al
    clc
    ret

.pf_not_found:
    stc
    ret

; ============================================================================
; apply_bg_override — Override config_buffer[0..2] if /b:color was given
; ============================================================================
apply_bg_override:
    cmp byte [bg_specified], 0
    je .abg_done
    mov al, [bg_color]
    mov [config_buffer], al
    mov al, [bg_color+1]
    mov [config_buffer+1], al
    mov al, [bg_color+2]
    mov [config_buffer+2], al
.abg_done:
    ret

; ============================================================================
; apply_fg_override — Override config_buffer[3..11] if /c:name,name,name
; ============================================================================
apply_fg_override:
    cmp byte [fg_specified], 0
    je .afg_done
    mov si, fg_colors
    mov di, config_buffer + 3
    mov cx, 9
    cld
    rep movsb
.afg_done:
    ret

; ============================================================================
; apply_adjustments — Apply /V, /P, /D from command line to config_buffer
; ============================================================================
apply_adjustments:
    push ax

    ; Vivid
    cmp byte [vivid_adj_cmd], 0
    je .adj_check_pop
    cmp byte [vivid_adj_cmd], 1
    je .adj_vivid_boost
    call inst_saturation_mute
    jmp .adj_check_pop
.adj_vivid_boost:
    call inst_saturation_boost

.adj_check_pop:
    ; Pop
    cmp byte [pop_flag_cmd], 0
    je .adj_check_bright
    call inst_saturation_boost
    call inst_contrast_boost

.adj_check_bright:
    ; Brightness
    cmp byte [brightness_adj_cmd], 0
    je .adj_done
    cmp byte [brightness_adj_cmd], 1
    je .adj_brighten
    call inst_dim
    jmp .adj_done
.adj_brighten:
    call inst_brighten

.adj_done:
    pop ax
    ret

; --- Installer adjustment routines (work on config_buffer, not palette_rgb) ---

inst_brighten:
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 9
.loop:
    mov al, [si]
    add al, 8
    cmp al, 63
    jbe .ok
    mov al, 63
.ok:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

inst_dim:
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 9
.loop:
    mov al, [si]
    sub al, 8
    jnc .ok
    xor al, al
.ok:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

inst_saturation_boost:
    push bx
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 3
.color:
    xor ax, ax
    mov al, [si]
    add al, [si+1]
    add al, [si+2]
    mov bl, 3
    div bl
    mov bl, al                 ; BL = gray
    push cx
    mov cx, 3
.ch:
    mov al, [si]
    sub al, bl
    sar al, 1
    add al, [si]
    test al, al
    jns .not_neg
    xor al, al
    jmp .store
.not_neg:
    cmp al, 63
    jbe .store
    mov al, 63
.store:
    mov [si], al
    inc si
    loop .ch
    pop cx
    loop .color
    pop si
    pop cx
    pop bx
    ret

inst_saturation_mute:
    push bx
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 3
.color:
    xor ax, ax
    mov al, [si]
    add al, [si+1]
    add al, [si+2]
    mov bl, 3
    div bl
    mov bl, al
    push cx
    mov cx, 3
.ch:
    mov al, [si]
    add al, bl
    shr al, 1
    mov [si], al
    inc si
    loop .ch
    pop cx
    loop .color
    pop si
    pop cx
    pop bx
    ret

inst_contrast_boost:
    push cx
    push si
    mov si, config_buffer + 3
    mov cx, 9
.loop:
    mov al, [si]
    sub al, 31
    sar al, 1
    add al, [si]
    test al, al
    jns .not_neg
    xor al, al
    jmp .store
.not_neg:
    cmp al, 63
    jbe .store
    mov al, 63
.store:
    mov [si], al
    inc si
    loop .loop
    pop si
    pop cx
    ret

; ============================================================================
; load_config — Load palette from file into config_buffer
; ============================================================================
load_config:
    push ax
    push bx
    push cx
    push dx

    call get_filename
    jc .use_default
    mov byte [explicit_file], 1
    jmp .open_file

.use_default:
    mov byte [explicit_file], 0
    mov dx, default_filename

.open_file:
    ; Open file for reading
    mov ax, 0x3D00
    int 0x21
    jc .file_error

    mov [file_handle], ax
    mov bx, ax

    ; Read up to TEXT_BUF_SIZE bytes
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

    ; Check file size
    mov ax, [bytes_read]
    or ax, ax
    jz .close_error

    ; Parse text file format
    call parse_text_palette
    jc .parse_error

    clc
    jmp .lc_done

.parse_error:
    mov dx, msg_parse_error
    call print_string
    stc
    jmp .lc_done

.close_error:
    mov ah, 0x3E
    mov bx, [file_handle]
    int 0x21

.file_error:
    cmp byte [explicit_file], 0
    je .silent_fail
    mov dx, msg_file_error
    call print_string
.silent_fail:
    stc

.lc_done:
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; parse_text_palette — Parse RGB text into config_buffer
; Parses up to 9 palettes (36 color lines). Sets [palettes_loaded] = 1..9.
; Returns: CF=0 success (at least 1 palette), CF=1 error
; ============================================================================
parse_text_palette:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov si, text_buffer
    mov di, config_buffer
    mov cx, [bytes_read]
    xor bx, bx                 ; BL = total color lines parsed (0..36)

.next_line:
    cmp bl, MAX_PALETTES * 4   ; 36 color lines max
    jae .parse_done
    or cx, cx
    jz .check_count

.skip_ws:
    or cx, cx
    jz .check_count
    lodsb
    dec cx
    cmp al, ' '
    je .skip_ws
    cmp al, 9                  ; Tab
    je .skip_ws
    cmp al, 13                 ; CR
    je .skip_ws
    cmp al, 10                 ; LF
    je .next_line

    ; Check for comment line
    cmp al, ';'
    je .skip_to_eol
    cmp al, '#'
    je .skip_to_eol

    ; Start of a number — back up
    dec si
    inc cx

    ; Parse Red value
    call parse_number
    jc .parse_fail
    mov [di], al

    ; Skip separator
    call skip_separator
    jc .parse_fail

    ; Parse Green value
    call parse_number
    jc .parse_fail
    mov [di+1], al

    ; Skip separator
    call skip_separator
    jc .parse_fail

    ; Parse Blue value
    call parse_number
    jc .parse_fail
    mov [di+2], al

    ; Advance to next color slot
    add di, 3
    inc bl

.skip_to_eol:
    or cx, cx
    jz .check_count
    lodsb
    dec cx
    cmp al, 10
    jne .skip_to_eol
    jmp .next_line

.check_count:
    cmp bl, 4
    jb .parse_fail             ; need at least 1 full palette

.parse_done:
    ; Calculate number of complete palettes parsed
    mov al, bl
    xor ah, ah
    mov dl, 4
    div dl                      ; AL = palettes (BL / 4)
    mov [palettes_loaded], al
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
; parse_number — Parse decimal 0-63 from SI/CX
; Output: AL = value, CF=0 success, CF=1 error
; ============================================================================
parse_number:
    push bx
    push dx

    xor ax, ax
    xor bx, bx

.digit_loop:
    or cx, cx
    jz .check_digits
    mov dl, [si]
    cmp dl, '0'
    jb .check_digits
    cmp dl, '9'
    ja .check_digits

    ; Accumulate: AX = AX * 10 + digit
    push dx
    mov dx, 10
    mul dx
    pop dx
    sub dl, '0'
    xor dh, dh
    add ax, dx
    inc si
    dec cx
    inc bx
    jmp .digit_loop

.check_digits:
    or bx, bx
    jz .num_error
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
; skip_separator — Skip comma, space, or tab between numbers
; ============================================================================
skip_separator:
    push ax
    or cx, cx
    jz .sep_error
.sep_loop:
    lodsb
    dec cx
    cmp al, ','
    je .sep_more
    cmp al, ' '
    je .sep_more
    cmp al, 9                  ; Tab
    je .sep_more
    cmp al, 10
    je .sep_error
    cmp al, 13
    je .sep_error
    ; Start of next number — back up
    dec si
    inc cx
    clc
    jmp .sep_done
.sep_more:
    or cx, cx
    jz .sep_error
    jmp .sep_loop
.sep_error:
    stc
.sep_done:
    pop ax
    ret

; ============================================================================
; get_filename — Extract filename from command line (skip switches)
; Output: DX = filename pointer, CF=0 found, CF=1 not found
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
    cmp al, '/'
    je .skip_token
    cmp al, '-'
    je .skip_token
    jmp .copy_loop

.skip_token:
    lodsb
    cmp al, ' '
    je .skip_spaces
    cmp al, 0x0D
    je .no_filename
    cmp al, 0x0A
    je .no_filename
    jmp .skip_token

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
    jmp .gf_done

.no_filename:
    stc

.gf_done:
    pop di
    pop si
    ret

; ============================================================================
; validate_palette — Check all loaded bytes in config_buffer are 0-63
; ============================================================================
validate_palette:
    push ax
    push cx
    push si
    mov al, [palettes_loaded]
    xor ah, ah
    mov cl, 12
    mul cl                      ; AX = total bytes to check
    mov cx, ax
    mov si, config_buffer
.check_loop:
    lodsb
    cmp al, 64
    jae .invalid
    loop .check_loop
    clc
    jmp .vp_done
.invalid:
    mov dx, msg_invalid
    call print_string
    stc
.vp_done:
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; load_fallback_to_config — Copy fallback CGA palette to config_buffer
; ============================================================================
load_fallback_to_config:
    push si
    push di
    push cx
    mov si, res_preset_fallback
    mov di, config_buffer
    mov cx, CONFIG_SIZE
    cld
    rep movsb
    mov byte [palettes_loaded], 1
    pop cx
    pop di
    pop si
    ret

; ============================================================================
; copy_file_palettes_to_presets — Copy palettes from config_buffer to
; resident presets. Palette 1 -> res_preset_1, etc. (up to 9).
; ============================================================================
copy_file_palettes_to_presets:
    push ax
    push cx
    push si
    push di

    mov al, [palettes_loaded]
    xor ah, ah
    or al, al
    jz .cpy_done

    mov si, config_buffer
    mov di, res_preset_1
    mov cl, 12
    mul cl                      ; AX = palettes_loaded x 12
    mov cx, ax
    cld
    rep movsb

.cpy_done:
    pop di
    pop si
    pop cx
    pop ax
    ret

; ============================================================================
; print_colors — Print loaded palette with color blocks
; ============================================================================
print_colors:
    push ax
    push bx
    push cx
    push si

    mov dx, msg_colors
    call print_string
    mov si, config_buffer
    mov cl, 0

.color_loop:
    mov dx, msg_color_prefix
    call print_string
    mov al, cl
    add al, '0'
    call print_char
    mov dx, msg_color_sep
    call print_string

    lodsb
    call print_number
    mov al, ','
    call print_char
    lodsb
    call print_number
    mov al, ','
    call print_char
    lodsb
    call print_number

    mov al, ' '
    call print_char
    mov al, cl
    call print_color_block

    mov dx, msg_crlf
    call print_string
    inc cl
    cmp cl, 4
    jb .color_loop

    pop si
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; print_color_block — 4 solid blocks in specified color attribute
; Maps color index 0-3 to text attributes: 0, 11, 13, 15
; ============================================================================
print_color_block:
    push ax
    push bx
    push cx
    mov bl, al
    or al, al
    jz .have_attr               ; Color 0 stays 0
    shl bl, 1                   ; BL = index * 2
    add bl, 9                   ; BL = 11, 13, or 15
.have_attr:
    mov bh, 0                   ; Page 0
    mov al, 219                 ; Solid block character
    mov cx, 4                   ; Print 4 blocks
    mov ah, 0x09                ; Write char with attribute
    int 0x10
    ; Move cursor forward 4 positions
    mov ah, 0x03
    mov bh, 0
    int 0x10                    ; DH=row, DL=column
    add dl, 4
    mov ah, 0x02
    int 0x10
    pop cx
    pop bx
    pop ax
    ret

; ============================================================================
; print_number — Print AL as decimal (0-99)
; ============================================================================
print_number:
    push ax
    push bx
    push dx
    xor ah, ah
    mov bl, 10
    div bl                      ; AL = tens, AH = ones
    or al, al
    jz .ones
    add al, '0'
    call print_char
.ones:
    mov al, ah
    add al, '0'
    call print_char
    pop dx
    pop bx
    pop ax
    ret

; ============================================================================
; print_char — Print character in AL via DOS
; ============================================================================
print_char:
    push ax
    push dx
    mov dl, al
    mov ah, 0x02
    int 0x21
    pop dx
    pop ax
    ret

; ============================================================================
; print_string — Print $-terminated string at DX via DOS
; ============================================================================
print_string:
    push ax
    mov ah, 0x09
    int 0x21
    pop ax
    ret

; ============================================================================
; Data Section (transient — discarded after TSR)
; ============================================================================

msg_banner:
    db 'PC1PalT v1.1 - CGA Palette TSR for Olivetti PC1', 13, 10
    db 'By Retro Erik - 2026 - Yamaha V6355D DAC Programmer', 13, 10
    db 'Type: PC1PALT /? for help', 13, 10, '$'

msg_help:
    db 13, 10
    db 'Usage: PC1PALT [file.txt] [/1..9] [/c:c1,c2,c3] [/b:color]', 13, 10
    db '               [/P] [/V:+|-] [/D:+|-] [/R] [/U] [/?]', 13, 10
    db 13, 10
    db '  Installs as TSR. Hooks INT 10h (survives game mode resets)', 13, 10
    db '  and INT 09h (live palette hotkeys via Ctrl+Alt).', 13, 10
    db 13, 10
    db '  file.txt       Load palette file (1-9 palettes, 4 lines each)', 13, 10
    db '  /c:c1,c2,c3    Set colors 1-3 by name (see list below)', 13, 10
    db '  /b:color        Set background color by name', 13, 10
    db '  /P              Pop - boost saturation + contrast', 13, 10
    db '  /V:+  /V:-      Increase / decrease saturation', 13, 10
    db '  /D:+  /D:-      Brighten / dim colors', 13, 10
    db '  /R              Install with default CGA palette', 13, 10
    db '  /U              Uninstall TSR from memory', 13, 10
    db '  /?              Show this help', 13, 10
    db '$'

msg_pause:
    db 13, 10, '--- Press any key for more ---', '$'

msg_help2:
    db 13, 10, 13, 10
    db 'Built-in presets:', 13, 10
    db '  /1  Arcade Vibrant   /2  Sierra Natural   /3  C64-inspired', 13, 10
    db '  /4  CGA Red/Green    /5  CGA Red/Blue     /6  Amstrad CPC', 13, 10
    db '  /7  Pastel           /8  Mono Amber       /9  Mono Green', 13, 10
    db 13, 10
    db 'Live hotkeys (hold Ctrl+Alt and press):', 13, 10
    db '  1..9       Switch preset instantly', 13, 10
    db '  P          Toggle Pop (saturation + contrast)', 13, 10
    db '  R          Reset to default CGA palette', 13, 10
    db '  Up/Down    Brighten / Dim', 13, 10
    db '  Left/Right Less / More vivid (saturation)', 13, 10
    db '  Space      Random from 15 CGA colors', 13, 10
    db '  C          Random from C64 palette', 13, 10
    db '  A          Random from Amstrad CPC palette', 13, 10
    db '  Z          Random from ZX Spectrum palette', 13, 10
    db '  Release Ctrl+Alt = normal keyboard', 13, 10
    db 13, 10
    db 'Color names for /c: and /b:', 13, 10
    db '  black, blue, green, cyan, red, magenta, brown, lightgray,', 13, 10
    db '  darkgray, lightblue, lightgreen, lightcyan, lightred,', 13, 10
    db '  lightmagenta, yellow, white', 13, 10
    db 13, 10
    db 'Text file: R,G,B per line (0-63). Up to 9 palettes (4 lines', 13, 10
    db 'each). Multi-palette files overwrite presets 1-9.', 13, 10
    db '$'

msg_preset1:     db 'Preset: Arcade Vibrant', 13, 10, '$'
msg_preset2:     db 'Preset: Sierra Natural', 13, 10, '$'
msg_preset3:     db 'Preset: C64-inspired', 13, 10, '$'
msg_preset4:     db 'Preset: CGA Red/Green/White', 13, 10, '$'
msg_preset5:     db 'Preset: CGA Red/Blue/White', 13, 10, '$'
msg_preset6:     db 'Preset: Amstrad CPC', 13, 10, '$'
msg_preset7:     db 'Preset: Pastel', 13, 10, '$'
msg_preset8:     db 'Preset: Monochrome Amber', 13, 10, '$'
msg_preset9:     db 'Preset: Monochrome Green', 13, 10, '$'
msg_resetting:   db 'Using default CGA palette.', 13, 10, '$'
msg_multi_loaded:
    db 'Multi-palette file: presets 1-9 overwritten.', 13, 10, '$'
msg_installed:
    db 'TSR installed. INT 09h + INT 10h hooked.', 13, 10
    db 'Ctrl+Alt + key = hotkeys (1-9/P/R/arrows/Space/C/A/Z).', 13, 10
    db 'Run your CGA game now. Use PC1PALT /U to uninstall.', 13, 10, '$'
msg_already_loaded:
    db 'PC1PalT already resident - palette updated.', 13, 10, '$'
msg_unloaded:
    db 'PC1PalT uninstalled. INT 09h + INT 10h restored.', 13, 10, '$'
msg_unload_error:
    db 'Error: PC1PalT not found in interrupt chain.', 13, 10, '$'
msg_colors:      db 'Colors (R,G,B):', 13, 10, '$'
msg_color_prefix:db '  Color $'
msg_color_sep:   db ': $'
msg_crlf:        db 13, 10, '$'
msg_fallback:    db 'Warning: palette load failed, using default.', 13, 10, '$'
msg_file_error:  db 'Warning: Cannot open palette file.', 13, 10, '$'
msg_parse_error: db 'Warning: Cannot parse palette file.', 13, 10, '$'
msg_invalid:     db 'Warning: Value out of range (must be 0-63).', 13, 10, '$'
msg_bad_bg:      db 'Warning: Unknown background color name. Use /? for list.', 13, 10, '$'
msg_bad_fg:      db 'Warning: Bad /c: colors. Use /c:name,name,name (see /?).', 13, 10, '$'
msg_bad_switch:  db 'Error: Unknown switch. Use /? for help.', 13, 10, '$'
msg_success:     db 'Palette written to V6355D DAC.', 13, 10, '$'

default_filename: db 'PC1PALT.TXT', 0

; ============================================================================
; Color name table (shared by /b: and /c: parsers)
; Format: null-terminated name, then 3 bytes of 6-bit RGB (0-63)
; ============================================================================
bg_color_names:
    db 'black', 0,          0,  0,  0
    db 'blue', 0,           0,  0, 42
    db 'green', 0,          0, 42,  0
    db 'cyan', 0,           0, 42, 42
    db 'red', 0,           42,  0,  0
    db 'magenta', 0,       42,  0, 42
    db 'brown', 0,         42, 21,  0
    db 'lightgray', 0,     42, 42, 42
    db 'darkgray', 0,      21, 21, 21
    db 'lightblue', 0,     21, 21, 63
    db 'lightgreen', 0,    21, 63, 21
    db 'lightcyan', 0,     21, 63, 63
    db 'lightred', 0,      63, 21, 21
    db 'lightmagenta', 0,  63, 21, 63
    db 'yellow', 0,        63, 63, 21
    db 'white', 0,         63, 63, 63
    db 0                    ; end of table

; ============================================================================
; Installer variables (transient)
; ============================================================================
explicit_file:      db 0
parse_error:        db 0
brightness_adj_cmd: db 0        ; 0=none, 1=brighten, 2=dim
vivid_adj_cmd:      db 0        ; 0=none, 1=boost, 2=mute
pop_flag_cmd:       db 0        ; 1=apply pop from command line
switch_result:      db 0
is_default_install: db 0
palettes_loaded:    db 1        ; number of palettes parsed from file (1-9)
bg_specified:       db 0
bg_color:           db 0, 0, 0
fg_specified:       db 0
fg_count:           db 0
fg_colors:          times 9 db 0
file_handle:        dw 0
bytes_read:         dw 0

filename_buffer:    times 128 db 0
config_buffer:      times MULTI_CONFIG_SIZE db 0
text_buffer:        times TEXT_BUF_SIZE db 0

; ============================================================================
; End of PC1PALT.ASM
; ============================================================================
