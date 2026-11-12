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

`bun run diff` runs every ROM in `roms/` through both cores with the same seed and key presses. It exits with an error at the first frame where the framebuffers differ. Build both cores and fetch the ROMs first.

See `SPEC.md` for the interface both cores implement.

## Comparison

Both cores pass the same 55 tests (49 for the CPU, 6 for the WASM exports) and the Timendus test ROMs, and `bun run diff` shows identical framebuffers.

| | Zig 0.17.0 | Rust (stable) |
| --- | --- | --- |
| Release `.wasm` | 9,249 bytes (`ReleaseSmall`) | 23,150 bytes (`--release`) |
| Source lines, tests excluded | about 295 | about 424 |
| Source lines, tests included | 811 | 1,018 |

Source lines count `root.zig` and `wasm.zig` against `lib.rs` and `wasm.rs`. `main.zig` is left out because the Rust core has no equivalent. Sizes and line counts are from the commit that added this table, so rebuild and recount before quoting them.
