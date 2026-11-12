// Runs every ROM in roms/ through both cores in lockstep and stops at the first differing frame.
import { Glob } from "bun";

// Per-ROM frame count and key script. 5-quirks waits at a menu until key 1 is pressed.
const scripts = { "5-quirks": { frames: 1500, press: 300, release: 310 } };

async function load(path) {
  if (!(await Bun.file(path).exists())) throw new Error(`${path} is missing, run bun run build:zig and bun run build:rust`);
  return (await WebAssembly.instantiate(await Bun.file(path).arrayBuffer(), {})).instance.exports;
}

const cores = [await load("web/zig.wasm"), await load("web/rust.wasm")];
const roms = [...new Glob("roms/*.ch8").scanSync()].sort();
if (!roms.length) throw new Error("roms/ is empty, run bun run roms");

for (const path of roms) {
  const name = path.slice(5, -4);
  const { frames = 300, press, release } = scripts[name] ?? {};
  const rom = new Uint8Array(await Bun.file(path).arrayBuffer());
  for (const c of cores) {
    new Uint8Array(c.memory.buffer, c.rom_ptr(), rom.length).set(rom);
    if (c.load_rom(rom.length, 1) !== 0) throw new Error(`${name}: load_rom failed`);
  }
  for (let f = 0; f < frames; f++) {
    for (const c of cores) {
      if (f === press) c.key_down(1);
      if (f === release) c.key_up(1);
      c.step(11);
      c.tick_timers();
    }
    const [a, b] = cores.map((c) => new Uint8Array(c.memory.buffer, c.framebuffer_ptr(), 64 * 32));
    const i = a.findIndex((v, j) => v !== b[j]);
    if (i >= 0) {
      console.error(`${name}: frame ${f} differs, first at x=${i % 64} y=${i >> 6} (zig ${a[i]}, rust ${b[i]})`);
      process.exit(1);
    }
  }
  console.log(`${name}: ${frames} frames match`);
}
