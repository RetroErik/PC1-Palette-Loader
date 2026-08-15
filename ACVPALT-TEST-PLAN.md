# ACVPALT hardware test plan

ACVPALT is a resident (TSR) CGA mode 4/5 palette utility, not a graphics
demo — it never sets a video mode itself and has no VRAM/framebuffer code.
It hooks `INT 10h` (to re-apply the palette after a game sets mode 4/5) and
`INT 09h` (for live Ctrl+Alt hotkeys). All tests below assume a CGA game or
a simple mode-4 test pattern is used to actually display the palette.

## Validation status

Validated on 2026-08-15 with a 12 MHz 80286 and ACV-1030 in all three
scenarios:

1. Ordinary CGA games on CGA/TTL: fixed IRGB colors, as expected.
2. Ordinary CGA games on composite: ACVPALT custom palette colors are
   visible.
3. Composite-mode games on composite: ACVPALT custom palette colors are
   visible.

## Scenario 1: Ordinary CGA Games on CGA/TTL

1. Boot DOS on the 12 MHz 80286 ACV-1030 target and run `ACVPALT /1` (or any
   preset/palette file). Confirm the banner prints, the loaded colors are
   listed, and the program goes resident with no error message.
2. Start an ordinary CGA mode-4 game or test pattern. Confirm the picture
   displays using the fixed CGA/TTL IRGB colors. The digital connector is
   fixed IRGB and is not changed by the V6355 DAC palette writes.
3. Hold Ctrl+Alt and press `0`-`9`, `P`, `R`, arrow keys, `Space`, `C`, `A`,
   `Z`. Confirm each hotkey is acknowledged (no keyboard lockup) and that
   the CGA/TTL picture colors remain fixed IRGB throughout.
4. Release Ctrl+Alt and confirm normal keystrokes pass through to the game
   unmodified.
5. Run `ACVPALT /U` and confirm it reports uninstalling and that `INT 09h`/
   `INT 10h` are restored (test by re-running `ACVPALT /U` again — it should
   report "not found in interrupt chain").

## Scenario 2: Ordinary CGA Games on Composite

1. Connect the ACV-1030 composite output to an NTSC composite monitor or
   capture device.
2. Run `ACVPALT` with a custom preset (e.g. `/6` Amstrad CPC) before
   starting an ordinary CGA mode-4 game. Confirm the composite picture
   shows the custom RGB colors from the preset, not the default CGA palette.
3. Confirm register `65h=01h` (200-line NTSC color CRT) keeps the composite
   image centered and free of the vertical roll seen with PAL timing.
4. Hold Ctrl+Alt and use `Up`/`Down` (brightness), `Left`/`Right`
   (saturation), and `P` (pop). Confirm each adjustment is visible on the
   composite output in real time.
5. Load a multi-palette `.txt` file (2+ palettes) and confirm hotkeys `1`-`9`
   switch between the file's palettes on composite output.
6. Run `ACVPALT /R` and confirm composite output reverts to the standard
   CGA-equivalent palette.

## Scenario 3: Composite-Mode Games on Composite

1. Connect the ACV-1030 composite output to an NTSC composite monitor or
   capture device and start a composite-mode game with ACVPALT resident.
2. Confirm the game displays custom palette colors on composite output.
3. Exercise the preset and live adjustment hotkeys and confirm palette
   changes remain visible while the game runs.
4. Exit the game and confirm the TSR can be uninstalled with `ACVPALT /U`.

## Port, register, and CPU checks

On the listing or with a logic probe, verify every V6355 access uses `DX`
loaded from a word constant with the full ports `3D8h`/`3D9h`/`3DDh`/`3DEh`
— never an 8-bit immediate `OUT`. Confirm `acv1030_init` runs once per
invocation and writes register `67h=18h`, then register `65h=01h`, with
`80h` written to `3DDh` before and after (ACVPALT never sends `4Ah` to
`3D8h` — it does not enable the 160x200x16 hidden mode).

Run the COM on the 12 MHz 80286 target with no video card acceleration
tricks. It must not depend on V40/80186-only instructions or any 386-only
near conditional jump (`0F 8x`/`0F 9x`) — confirmed at build time by
assembling with `CPU 286`, which NASM rejects if such an encoding is
required. Record display type, preset/file used, visible palette result,
hotkey response, and uninstall result for each test.
