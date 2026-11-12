const OCTO = 0b001110;
const SEED = 1;
const STEPS = 20_000_000;
const ROUNDS = 7;
const MILLION = 1e6;

const opcodes = {
  v0IsZero: 0x6000,
  v1IsFive: 0x6105,
  addThreeToV0: 0x7003,
  addV1ToV0: 0x8014,
  xorV0IntoV1: 0x8103,
  iIs0x300: 0xa300,
  storeV0AndV1: 0xf155,
  loadV0AndV1: 0xf165,
  iIsTheFont: 0xa050,
  drawFiveRows: 0xd015,
  jumpToAddThree: 0x1204,
};
const MIXED_LOOP = Uint8Array.from(Object.values(opcodes).flatMap((word) => [word >> 8, word & 0xff]));

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
