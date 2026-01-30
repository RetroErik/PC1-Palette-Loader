# PC1PAL - CGA Palette Loader for Olivetti Prodest PC1

A tiny DOS utility that loads custom RGB palettes for CGA games on the Olivetti Prodest PC1. The PC1 uses the Yamaha V6355D video chip with a programmable 16-entry RGB DAC.

## Features

- Loads custom 4-color palettes for CGA 320×200 mode
- Supports both **binary** (12 bytes) and **text** file formats
- Works with all CGA palette modes (palette 0/1, low/high intensity)
- Fallback to standard CGA palette if file missing
- No TSR needed - palette persists across mode changes
- Clean exit to DOS for launching CGA games

## Hardware

The Olivetti Prodest PC1 uses the **Yamaha V6355D** video controller which has:
- 16-entry programmable palette
- 3-bit per channel RGB DAC (8 levels per color = 512 colors total)
- I/O ports at 0xDD (address) and 0xDE (data)

### CGA Mode 4 Palette Mapping

In CGA 320×200 4-color mode, pixel values 0-3 map to DAC entries based on which palette the game uses:

| Pixel | Palette 1 (Cyan/Mag/White) | Palette 0 (Green/Red/Yellow) |
|-------|---------------------------|------------------------------|
| 0 | Entry 0 | Entry 0 |
| 1 | Entry 3 or 11 | Entry 2 or 10 |
| 2 | Entry 5 or 13 | Entry 4 or 12 |
| 3 | Entry 7 or 15 | Entry 6 or 14 |

PC1PAL writes your 4 custom colors to **all** these positions, so your palette works regardless of which CGA palette or intensity the game uses.

## Usage

```
PC1PAL [palette.pal]
```

- If no filename specified, uses `PC1PAL.PAL` in current directory
- If file missing or invalid, uses fallback CGA palette (Black/Cyan/Magenta/White)

### Example

```
C:\GAMES> PC1PAL SUNSET.TXT
PC1PAL - CGA Palette Loader for Olivetti PC1
Yamaha V6355D DAC Programmer
Text palette file loaded.
Palette written to DAC.
Ready to run CGA programs!

C:\GAMES> MONKEY.EXE
```

## Config File Formats

### Text Format (Recommended)

Human-readable format with comments:

```ini
; SUNSET.TXT - Warm sunset palette
; Values are 0-63 (6-bit RGB)

0,0,0       ; Color 0: Black (background)
42,0,21     ; Color 1: Deep Magenta
63,21,0     ; Color 2: Orange
63,63,0     ; Color 3: Yellow
```

- One RGB triple per line: `R,G,B` or `R G B`
- Lines starting with `;` or `#` are comments
- Blank lines are ignored
- Values must be 0-63

### Binary Format

12 bytes total: 4 RGB triples × 3 bytes each

| Offset | Description | Range |
|--------|-------------|-------|
| 0-2 | Color 0: R, G, B | 0-63 |
| 3-5 | Color 1: R, G, B | 0-63 |
| 6-8 | Color 2: R, G, B | 0-63 |
| 9-11 | Color 3: R, G, B | 0-63 |

Files exactly 12 bytes are treated as binary; larger files are parsed as text.

## Included Palettes

| File | Colors | Description |
|------|--------|-------------|
| TANDY.PAL | Black, Sky Blue, Orange, White | Tandy-style enhanced |
| TANDY.TXT | Same as above | Text format version |
| SUNSET.PAL | Black, Deep Magenta, Orange, Yellow | Warm sunset theme |
| SUNSET.TXT | Same as above | Text format version |

## Building

Requires [NASM](https://nasm.us/) (Netwide Assembler):

```bash
nasm -f bin PC1PAL.asm -o PC1PAL.COM
```

## Creating Custom Palettes

Use any text editor to create a `.TXT` file:

```ini
; My custom palette
0,0,0       ; Background (usually black)
0,63,63     ; Color 1 (replaces Cyan)
63,0,63     ; Color 2 (replaces Magenta)  
63,63,63    ; Color 3 (replaces White)
```

Or use the included `mkpal.py` Python script to generate binary `.PAL` files.

## Technical Details

### V6355D Palette Format

The V6355D uses a packed 2-byte format per palette entry:

| Byte | Bits | Content |
|------|------|---------|
| 1 | 2:0 | Red (0-7) |
| 2 | 6:4 | Green (0-7) |
| 2 | 2:0 | Blue (0-7) |

6-bit input values (0-63) are scaled to 3-bit (0-7) by dividing by 8.

### Customizing I/O Ports

If your hardware uses different ports, modify these constants in PC1PAL.asm:

```nasm
PORT_REG_ADDR   equ 0xDD        ; Register Bank Address Port
PORT_REG_DATA   equ 0xDE        ; Register Bank Data Port
```

## License

MIT License - See [LICENSE](LICENSE) file

## Author

Retro Erik - 2026
