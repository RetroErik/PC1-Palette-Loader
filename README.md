# PC1PAL - CGA Palette Loader for Olivetti Prodest PC1

A tiny DOS utility that loads custom RGB palettes for CGA games on the Olivetti Prodest PC1. The PC1 uses the Yamaha V6355D video chip with a programmable 16-entry RGB DAC.

## Features

- Loads custom 4-color palettes for CGA 320×200 mode
- **3 built-in presets** for quick palette switching
- Supports human-readable text file format with comments
- Works with all CGA palette modes (palette 0/1, low/high intensity)
- Displays loaded colors with colored blocks
- Fallback to standard CGA palette if file missing
- No TSR needed - palette persists until mode change
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
PC1PAL [file.txt] [/1] [/2] [/3] [/R] [/?]
```

| Option | Description |
|--------|-------------|
| `file.txt` | Load palette from text file (default: PC1PAL.TXT) |
| `/1` | Preset: Arcade Vibrant (action games) |
| `/2` | Preset: Sierra Natural (adventure games) |
| `/3` | Preset: C64-inspired (retro warm feel) |
| `/R` | Reset to default CGA palette |
| `/?` | Show help |

### Examples

```
C:\GAMES> PC1PAL /1
PC1PAL v1.1 - CGA Palette Loader for Olivetti PC1
By Erik - 2026 - Yamaha V6355D DAC Programmer
Loading preset: Arcade Vibrant
Colors (R,G,B):
  Color 0: 0,0,0 ████
  Color 1: 9,27,63 ████
  Color 2: 63,9,9 ████
  Color 3: 63,45,27 ████
Palette written to DAC.
Ready to run CGA programs!

C:\GAMES> KARATE.EXE
```

```
C:\GAMES> PC1PAL SUNSET.TXT
```

## Built-in Presets

| Preset | Name | Colors (RGB 0-63) | Best For |
|--------|------|-------------------|----------|
| `/1` | Arcade Vibrant | Black, Blue(9,27,63), Red(63,9,9), Skin(63,45,27) | Action games |
| `/2` | Sierra Natural | Black, Teal(9,36,36), Brown(36,18,9), Skin(63,45,36) | Adventure games |
| `/3` | C64-inspired | Black, Blue(18,27,63), Orange(54,27,9), Skin(63,54,36) | Retro warm feel |

## Text File Format

Human-readable format with comments:

```ini
; SUNSET.TXT - Warm sunset palette
; Values are 0-63 (6-bit RGB)

0,0,0       ; Color 0: Black (background)
63,32,0     ; Color 1: Orange
32,0,16     ; Color 2: Dark Magenta
63,63,32    ; Color 3: Pale Yellow
```

- One RGB triple per line: `R,G,B` or `R G B`
- Lines starting with `;` or `#` are comments
- Blank lines are ignored
- Values must be 0-63 (will be scaled to 0-7 for V6355D)

## Included Palette Files

| File | Colors | Description |
|------|--------|-------------|
| SUNSET.TXT | Black, Orange, Dark Magenta, Pale Yellow | Warm sunset theme |

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

## Technical Details

For comprehensive V6355D documentation, see [V6355D-Technical-Reference.md](../V6355D-Technical-Reference.md).

### V6355D Palette Format

The V6355D uses a packed 2-byte format per palette entry:

| Byte | Bits | Content |
|------|------|---------|
| 1 | 2:0 | Red (0-7) |
| 2 | 6:4 | Green (0-7) |
| 2 | 2:0 | Blue (0-7) |

6-bit input values (0-63) are scaled to 3-bit (0-7) by dividing by 8.

### Palette Write Sequence

1. Write 0x40 to port 0xDD (enable palette write)
2. Write 32 bytes to port 0xDE (16 colors × 2 bytes each)
3. Write 0x80 to port 0xDD (disable palette write)

> **⚠️ Important:** You must include I/O delays between each palette byte write (e.g., `jmp short $+2`). The V6355D requires 300ns minimum I/O cycle time. Without delays, palette writes may be corrupted.

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
