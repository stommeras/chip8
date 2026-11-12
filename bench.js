const OCTO = 0b001110;
const SEED = 1;
const STEPS = 20_000_000;
const ROUNDS = 7;
const MILLION = 1e6;

// 6000 V0 = 0, 6105 V1 = 5, then loop: 7003 add 3 to V0, 8014 V0 += V1, 8103 V1 ^= V0,
// A300 I = 0x300, F155 store V0 and V1, F165 load them back, A050 I = the font, D015 draw 5 rows,
// 1204 jump to the loop.
const MIXED_LOOP = Uint8Array.of(
  0x60, 0x00, 0x61, 0x05, 0x70, 0x03, 0x80, 0x14, 0x81, 0x03, 0xa3, 0x00, 0xf1, 0x55, 0xf1, 0x65, 0xa0, 0x50, 0xd0, 0x15, 0x12, 0x04,
);

for (const name of ["zig", "rust"]) {
  const path = `web/${name}.wasm`;
  if (!(await Bun.file(path).exists())) throw new Error(`${path} is missing, run bun run build:${name}`);
  const core = (await WebAssembly.instantiate(await Bun.file(path).arrayBuffer(), {})).instance.exports;
  new Uint8Array(core.memory.buffer, core.rom_ptr(), MIXED_LOOP.length).set(MIXED_LOOP);
  if (core.load_rom(MIXED_LOOP.length, SEED, OCTO) !== 0) throw new Error(`${name}: load_rom failed`);
  core.step(STEPS);

  const rates = [];
  const screens = new Set();
  for (let i = 0; i < ROUNDS; i++) {
    const start = performance.now();
    core.step(STEPS);
    rates.push(STEPS / MILLION / ((performance.now() - start) / 1000));
    screens.add(new Bun.CryptoHasher("sha256").update(new Uint8Array(core.memory.buffer, core.framebuffer_ptr(), 64 * 32)).digest("hex"));
  }
  if (core.is_stopped()) throw new Error(`${name}: the machine stopped, so the rate means nothing`);
  if (screens.size < 2) throw new Error(`${name}: the screen never changed, so the program is not doing its work`);
  rates.sort((a, b) => a - b);
  const median = rates[Math.floor(ROUNDS / 2)];
  console.log(`${name}: ${median.toFixed(0)} million instructions per second (median of ${ROUNDS}, range ${rates[0].toFixed(0)} to ${rates[ROUNDS - 1].toFixed(0)})`);
}
