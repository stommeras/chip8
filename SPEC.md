# WASM interface

Both cores export exactly these functions with these names. All values are `u32`. Pointers are byte offsets into the module's exported `memory`.

| Export | Does |
| --- | --- |
| `rom_ptr() -> u32` | Returns a pointer to a 3584-byte buffer. The host writes the ROM here before calling `load_rom` |
| `load_rom(len, seed) -> u32` | Resets the machine, copies `len` bytes from the ROM buffer to 0x200, and seeds the random generator used by `CXNN`. Returns 0 on success, 1 if `len` is over 3584 |
| `step(n)` | Runs up to `n` instructions. Returns early after a `DXYN` (see quirks) |
| `tick_timers()` | Decrements the delay and sound timers. The host calls it 60 times a second |
| `key_down(k)`, `key_up(k)` | Presses or releases key `k`, from 0x0 to 0xF |
| `framebuffer_ptr() -> u32` | Returns a pointer to 64×32 bytes, row by row, 0 for off and 1 for on |
| `sound_on() -> u32` | Returns 1 while the sound timer is above 0 |

The cores import nothing from the host.

## Timing

The host decides the speed. The default is `step(11)` and then `tick_timers()` once per frame at 60 fps, which comes to about 660 instructions per second.

## Quirks

The cores follow the original COSMAC VIP:

- `8XY1`, `8XY2` and `8XY3` reset VF to 0
- `8XY6` and `8XYE` shift VY and store the result in VX
- `FX55` and `FX65` leave I incremented by X + 1
- `BNNN` jumps to NNN + V0
- `DXYN` clips sprites at the screen edge instead of wrapping, and ends the current `step` call so the host can draw. This is the "display wait" quirk

The quirks test in the Timendus chip8-test-suite checks all of these.
