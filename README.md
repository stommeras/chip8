# chip8

A CHIP-8 emulator written twice, in Zig and in Rust. Both compile to WebAssembly and run on the same web page, so you can switch between them while playing.

## Run it

Needs Zig, Rust with the `wasm32-unknown-unknown` target, and Bun.

```sh
bun run build:zig
bun run build:rust
bun run dev
```

See `SPEC.md` for the interface both cores implement.
