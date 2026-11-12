# chip8

A CHIP-8 emulator written twice, in Zig and in Rust. Both compile to WebAssembly and run on the same web page, so you can switch between them while playing.

## Run it

Needs Zig, Rust with the `wasm32-unknown-unknown` target, and Bun.

```sh
bun run build:zig
bun run build:rust
bun run dev
```

Pick a game from the "Game" menu. Choosing one sets the quirks and the speed it was written for. To run another ROM, use the file chooser. `bun run roms` fetches the Timendus test ROMs into `roms/`, which `bun run diff` needs.

On the page, the keys 1 2 3 4 / Q W E R / A S D F / Z X C V map to the CHIP-8 keypad, and P pauses. The "Quirks" menu switches between COSMAC VIP and Octo (modern CHIP-8) behavior, which most games expect, and restarts the ROM. Neither core runs the SUPER-CHIP instructions, such as the 128x64 screen, so a ROM that needs them stops and the page says so. The "Steps per frame" field sets the speed (11 by default, about 660 instructions per second). Under the screen, the page shows the size of the loaded `.wasm` file and the average time the core spends on one frame. The browser rounds timers, so only the average over a second means anything.

`cd zig && zig build run -- ../roms/2-ibm-logo.ch8` runs a ROM for 1000 instructions and prints the screen as text. The Rust core has no equivalent.

## Games

`web/games/` holds ten games from the [chip8Archive](https://github.com/JohnEarnest/chip8Archive), whose Readme puts everything in it under CC0. `web/games/games.json` has the title, author, source link, quirks value and speed of each. The quirks come from the flags the archive lists for each game, translated to the values in `SPEC.md`. To add a game, copy its ROM there and add an entry.

## Tests

```sh
(cd zig && zig build test)
(cd rust && cargo test)
```

`bun run diff` runs every ROM in `roms/` through both cores with the same seed and key presses, once for each of ten quirks settings: the three presets, none, and each VIP quirk cleared on its own. It exits with an error at the first frame where the framebuffers differ. It also hashes the final screen of each Timendus test ROM under the VIP quirks and compares it with the hash stored in `diff.js`, and it fails if one of those ROMs is missing. The other quirks settings only get the lockstep comparison. The stored screens are the logo for the two logo ROMs and a tick for every test on the other three. A changed hash means a core changed what a ROM shows or the ROM itself changed. Build both cores and fetch the ROMs first.

See `SPEC.md` for the interface both cores implement.

## Comparison

Both cores pass the same 65 tests (55 for the CPU, 10 for the WASM exports) and the Timendus test ROMs, and `bun run diff` shows identical framebuffers.

| | Zig 0.17.0 | Rust (stable) |
| --- | --- | --- |
| Release `.wasm` | 9,249 bytes (`ReleaseSmall`) | 23,150 bytes (`--release`) |
| Source lines, tests excluded | about 295 | about 424 |
| Source lines, tests included | 811 | 1,018 |

Source lines count `root.zig` and `wasm.zig` against `lib.rs` and `wasm.rs`. `main.zig` is left out because the Rust core has no equivalent. Sizes and line counts are from the commit that added this table, so rebuild and recount before quoting them.
