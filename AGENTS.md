# chip8

Two CHIP-8 emulators, one in Zig and one in Rust, that implement the same WASM interface and share one web page. It's a practice run before a fantasy console, and the point is to compare the two languages.

## Layout

- `zig/` and `rust/`: one emulator core each, compiled to `wasm32`
- `web/`: plain HTML and JavaScript, no bundler. It loads either core and draws to a `<canvas>`
- `roms/`: test ROMs and games. Commit only ROMs whose license allows it
- `SPEC.md`: the WASM interface both cores export. Change it only together with both cores and `web/`

## Versions

- Zig: **TODO, pin the version**. Zig breaks its std library and build system between releases, and your training data is likely older than this version. Don't write Zig from memory. Check the std source for this version (`zig env` prints `lib_dir`) or the language reference at ziglang.org/documentation/<version>/. When the compiler disagrees with you, the compiler is right.
- Rust: pinned in `rust/rust-toolchain.toml`.

## Conventions

- Use Bun for scripts in `package.json`.
- A change is done when `zig build test` in `zig/` and `cargo test` in `rust/` both pass.
- Keep the two cores comparable. Same structure, same tests, no feature in one that the other lacks.
- Branches are `<type>/<short-description>`, commits are Conventional Commits, and changes merge to `main` through a pull request.
