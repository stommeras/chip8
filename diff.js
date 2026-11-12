import { Glob } from "bun";

const VIP = 0b11111;
const masks = [VIP, 0, ...[0, 1, 2, 3, 4].map((bit) => VIP ^ (1 << bit))];
// 5-quirks waits at a menu until key 1 is pressed.
const scripts = { "5-quirks": { frames: 1500, press: 300, release: 310 } };

// Hashes of the final screen of each test ROM under the VIP quirks, when it shows every test passed.
const expected = {
  "1-chip8-logo": "aec99a55453e7002",
  "2-ibm-logo": "b12be07c247d2a94",
  "3-corax+": "f7accf00a65c264f",
  "4-flags": "c9b71cf8aa770baf",
  "5-quirks": "f8ab85a05e8e56bb",
};

async function load(path) {
  if (!(await Bun.file(path).exists())) throw new Error(`${path} is missing, run bun run build:zig and bun run build:rust`);
  return (await WebAssembly.instantiate(await Bun.file(path).arrayBuffer(), {})).instance.exports;
}

const cores = [await load("web/zig.wasm"), await load("web/rust.wasm")];
const roms = [...new Glob("roms/*.ch8").scanSync()].sort();
if (!roms.length) throw new Error("roms/ is empty, run bun run roms");

for (const path of roms) for (const quirks of masks) {
  const romName = path.slice(5, -4);
  const name = `${romName} (quirks ${quirks.toString(2).padStart(5, "0")})`;
  const { frames = 300, press, release } = scripts[romName] ?? {};
  const rom = new Uint8Array(await Bun.file(path).arrayBuffer());
  for (const c of cores) {
    new Uint8Array(c.memory.buffer, c.rom_ptr(), rom.length).set(rom);
    if (c.load_rom(rom.length, 1, quirks) !== 0) throw new Error(`${name}: load_rom failed`);
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
    if (cores[0].is_stopped() !== cores[1].is_stopped()) {
      console.error(`${name}: frame ${f}, the cores disagree on whether the machine stopped`);
      process.exit(1);
    }
  }
  const screen = new Uint8Array(cores[0].memory.buffer, cores[0].framebuffer_ptr(), 64 * 32);
  const hash = new Bun.CryptoHasher("sha256").update(screen).digest("hex").slice(0, 16);
  if (quirks === VIP && romName in expected && hash !== expected[romName]) {
    console.error(`${name}: the final screen is ${hash}, expected ${expected[romName]}`);
    for (let y = 0; y < 32; y++) console.error([...screen.slice(y * 64, y * 64 + 64)].map((p) => (p ? "#" : ".")).join(""));
    process.exit(1);
  }
  console.log(`${name}: ${frames} frames match`);
}
