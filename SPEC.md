# WASM interface

Both cores export exactly these functions with these names. All values are `u32`. Pointers are byte offsets into the module's exported `memory`.

| Export | Does |
| --- | --- |
| `rom_ptr() -> u32` | Returns a pointer to a 3584-byte buffer. The host writes the ROM here before calling `load_rom` |
| `load_rom(len, seed, quirks) -> u32` | Resets the machine, copies `len` bytes from the ROM buffer to 0x200, seeds the random generator used by `CXNN`, and sets the quirks (see below). Returns 0 on success, 1 if `len` is over 3584, and then nothing changes |
| `step(n)` | Runs up to `n` instructions. Returns early after a `DXYN` (see quirks) |
| `tick_timers()` | Decrements the delay and sound timers. The host calls it 60 times a second |
| `key_down(k)`, `key_up(k)` | Presses or releases key `k`, from 0x0 to 0xF |
| `framebuffer_ptr() -> u32` | Returns a pointer to 64×32 bytes, row by row, 0 for off and 1 for on |
| `sound_on() -> u32` | Returns 1 while the sound timer is above 0 |
| `is_stopped() -> u32` | Returns 1 after an error has stopped the machine (see Errors), until the next `load_rom` |

The cores import nothing from the host.

## Errors

The release builds don't check array bounds, so the cores check for themselves. An unknown opcode, a 17th nested `2NNN` call, or `00EE` with an empty stack stops the machine. `step` then does nothing until the next `load_rom`. Inside each core these are ordinary errors that the tests can see, and only the WASM exports turn them into "stopped".

## Timing

The host decides the speed. The default is `step(11)` and then `tick_timers()` once per frame at 60 fps, which comes to about 660 instructions per second.

## Random

`CXNN` uses xoshiro256++. `load_rom` expands the seed into the generator's four 64-bit words with SplitMix64, as the xoshiro reference code suggests, and each `CXNN` takes the low byte of one 64-bit output. Both cores give the same `CXNN` values for the same seed.

## Quirks

`load_rom` takes a bitmask. A set bit gives the COSMAC VIP behavior and a clear bit gives the SUPER-CHIP behavior. Bits above bit 4 are ignored.

| Bit | Name | Set (VIP) | Clear (SUPER-CHIP) |
| --- | --- | --- | --- |
| 0 | `vf_reset` | `8XY1`, `8XY2` and `8XY3` reset VF to 0 | VF is left alone |
| 1 | `shift_uses_vy` | `8XY6` and `8XYE` shift VY and store the result in VX | They shift VX in place |
| 2 | `increment_i` | `FX55` and `FX65` leave I incremented by X + 1 | I is left alone |
| 3 | `jump_uses_v0` | `BNNN` jumps to NNN + V0 | `BXNN` jumps to XNN + VX |
| 4 | `display_wait` | `DXYN` ends the current `step` call so the host can draw | `step` carries on |

The VIP value is 31 and the SUPER-CHIP value is 0. CHIP-48 matches SUPER-CHIP except that it raises I by X after `FX55` and `FX65`, which the cores don't model.

These behave the same under every setting:

- `FX0A` waits until a key is pressed **and released**, then stores that key in VX
- `DXYN` clips sprites at the screen edge instead of wrapping

The quirks test in the Timendus chip8-test-suite checks all of these under the VIP value.
