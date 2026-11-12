# chip8

A CHIP-8 emulator written twice, in Zig and in Rust. Both compile to WebAssembly and run on the same web page, so you can switch between them while playing.

## Run it

Needs Zig, Rust with the `wasm32-unknown-unknown` target, and Bun.

```sh
bun run build:zig
bun run build:rust
bun run dev
```

Run `bun run roms` once to fetch the test ROMs, then pick one from `roms/` with the file chooser on the page.

On the page, the keys 1 2 3 4 / Q W E R / A S D F / Z X C V map to the CHIP-8 keypad, and P pauses. The "Quirks" menu switches between COSMAC VIP and SUPER-CHIP quirks. Neither core runs the SUPER-CHIP instructions, such as the 128x64 screen, so a ROM that needs them stops and the page says so and restarts the ROM. The "Steps per frame" field sets the speed (11 by default, about 660 instructions per second). Under the screen, the page shows the size of the loaded `.wasm` file and the average time the core spends on one frame. The browser rounds timers, so only the average over a second means anything.

`cd zig && zig build run -- ../roms/2-ibm-logo.ch8` runs a ROM for 1000 instructions and prints the screen as text. The Rust core has no equivalent.

## Tests

```sh
(cd zig && zig build test)
(cd rust && cargo test)
```

`bun run diff` runs every ROM in `roms/` through both cores with the same seed and key presses, once with each quirks setting. It exits with an error at the first frame where the framebuffers differ. It also hashes the final screen of each Timendus test ROM under the VIP quirks and compares it with the hash stored in `diff.js`, and it fails if one of those ROMs is missing. The other quirks settings only get the lockstep comparison. The stored screens are the logo for the two logo ROMs and a tick for every test on the other three. A changed hash means a core changed what a ROM shows or the ROM itself changed. Build both cores and fetch the ROMs first.

See `SPEC.md` for the interface both cores implement.

## Comparison

Both cores pass the same 63 tests (54 for the CPU, 9 for the WASM exports) and the Timendus test ROMs, and `bun run diff` shows identical framebuffers.

| | Zig 0.17.0 | Rust (stable) |
| --- | --- | --- |
| Release `.wasm` | 9,249 bytes (`ReleaseSmall`) | 23,150 bytes (`--release`) |
| Source lines, tests excluded | about 295 | about 424 |
| Source lines, tests included | 811 | 1,018 |

Source lines count `root.zig` and `wasm.zig` against `lib.rs` and `wasm.rs`. `main.zig` is left out because the Rust core has no equivalent. Sizes and line counts are from the commit that added this table, so rebuild and recount before quoting them.
