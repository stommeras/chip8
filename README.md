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
