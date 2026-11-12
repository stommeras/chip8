# chip8

A CHIP-8 emulator written twice, in Zig and in Rust. Both compile to WebAssembly, export the same functions (see `SPEC.md`) and run on the same web page, so you can switch between them while a game is running. The project is a practice run before a fantasy console, and the point is to compare the two languages.

## Run it

You need Zig 0.17.1, Rust with the `wasm32-unknown-unknown` target (`rust/rust-toolchain.toml` installs it through rustup) and Bun.

```sh
bun run build:zig
bun run build:rust
bun run dev
```

Open the address `bun run dev` prints and pick a game.

| Command | What it does |
| --- | --- |
| `bun run build:zig` | Builds the Zig core with `ReleaseSmall` and copies it to `web/zig.wasm` |
| `bun run build:rust` | Builds the Rust core with `--release` and copies it to `web/rust.wasm` |
| `bun run dev` | Serves `web/` |
| `bun run roms` | Downloads the five Timendus test ROMs into `roms/` |
| `bun run diff` | Runs the ROMs and games through both cores and compares them (see Tests) |
| `bun run bench` | Measures how many instructions per second each core runs |

`cd zig && zig build run -- ../roms/2-ibm-logo.ch8` runs a ROM for 1000 instructions and prints the screen as text. The Rust core has no equivalent.

## The page

- **Game** lists the games in `web/games/`. Choosing one loads it, sets the quirks and speed it was written for, and shows how to play it.
- **ROM** runs any `.ch8` file from disk. It keeps the current quirks and speed.
- **Core** switches between Zig and Rust and restarts the ROM.
- **Quirks** switches between COSMAC VIP and Octo (modern CHIP-8) behavior and restarts the ROM. Most games expect Octo. `SPEC.md` lists what each quirk changes.
- **Steps per frame** sets the speed. The default of 11 is about 660 instructions per second.
- **Pause** stops the machine. The P key does the same.
- **Mute** silences the beep. The M key does the same.

The keys 1 2 3 4 / Q W E R / A S D F / Z X C V map to the CHIP-8 keypad.

The screen scales by a whole number of device pixels per CHIP-8 pixel, so the pixels stay square. In a 768 pixel column at 100% zoom that is 12.

Under the screen, the page shows the size of the loaded `.wasm` file and the average time the core spends on one frame. The browser rounds timers, so only the average over a second means anything.

Neither core runs the SUPER-CHIP instructions, such as the 128x64 screen. A ROM that needs them stops on an unknown opcode, and the page says so.

## Games

`web/games/` holds ten games from the [chip8Archive](https://github.com/JohnEarnest/chip8Archive), whose Readme puts everything in it under CC0. `web/games/games.json` has the title, author, source link, quirks value and speed of each. The quirks come from the flags the archive lists for each game, translated to the values in `SPEC.md`. To add a game, copy its ROM there and add an entry.

The Timendus test ROMs are GPL-3.0, so they are not in the repo. `bun run roms` downloads them.

## Tests

```sh
(cd zig && zig build test)
(cd rust && cargo test)
```

Both cores have the same 65 tests: 55 for the CPU and 10 for the WASM exports.

`bun run diff` needs both cores built and the test ROMs downloaded. It does three things.

- It runs every ROM in `roms/` through both cores with the same seed and key presses, once for each of ten quirks settings: the three presets, none, and each VIP quirk cleared on its own. It exits with an error at the first frame where the framebuffers differ.
- It hashes the final screen of each Timendus test ROM under the VIP quirks and compares it with the hash stored in `diff.js`. It fails if one of those ROMs is missing. The stored screens are the logo for the two logo ROMs and a tick for every test on the other three. A changed hash means a core changed what a ROM shows or the ROM itself changed.
- It runs every game in `web/games/` for 900 frames on both cores with the game's own quirks and speed, pressing a new key every 40 frames, and fails if the cores differ or the machine stops.

Continuous integration runs both test suites, both builds and `bun run diff` on every pull request.

## Comparison

| | Zig | Rust |
| --- | --- | --- |
| Release `.wasm` | 9,540 bytes | 23,605 bytes |
| Source lines, tests excluded | 336 | 502 |
| Source lines, tests included | 955 | 1,200 |
| Clean release build | about 2.9 s | about 0.2 s |
| Instructions per second | 160 to 170 million | about 115 million |

These numbers come from Zig 0.17.1 and Rust 1.99.1 on one Linux machine. Rebuild and rerun before quoting any of it.

- **Build settings.** Both cores are built for size, and the speed row measures those builds. Zig uses `ReleaseSmall`. Rust uses `opt-level = "z"`, LTO, one codegen unit, `panic = "abort"` and `strip` from `rust/Cargo.toml`.
- **Source lines** count `root.zig` and `wasm.zig` against `lib.rs` and `wasm.rs` with `wc -l`. "Tests excluded" counts `root.zig` up to its test helpers (`machineWith`), `wasm.zig` up to its test constants (`vip_bits`), and `lib.rs` and `wasm.rs` up to `#[cfg(test)]`. `main.zig` is left out because the Rust core has no equivalent.
- **Build time** is the time of `bun run build:zig` and `bun run build:rust` after deleting `zig/.zig-cache`, `zig/zig-out` and `rust/target`. The Rust crate has no dependencies, while the Zig build also compiles its standard library for WebAssembly.
- **Speed** comes from `bun run bench`. It loads a 22-byte program (see `MIXED_LOOP` in `bench.js`) that loops over arithmetic, `FX55`, `FX65` and `DXYN`, runs it for 20 million instructions seven times, and takes the median. It runs inside Bun's WebAssembly engine, not a browser, and it uses one small program, so only the ratio between the cores means much. It fails if the machine stops or the screen never changes.

A few differences you can see in the code:

- **Addresses.** Zig stores them as `u12`, so they cannot point past memory and `+%` wraps them at 0xFFF. Rust keeps `u16` and masks with `ADDRESS_MASK` to wrap at 0xFFF.
- **Quirks.** Zig declares `Quirks` as a `packed struct(u8)` and turns the bitmask into one with `@bitCast`. Rust writes out `Quirks::from_bits`.
- **State behind the exports.** Zig keeps the machine in module-level variables. Rust keeps it in a `thread_local!` `RefCell` and borrows it in each export.
