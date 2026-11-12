const OCTO = 0b001110;
const STEPS = 20_000_000;
const ROUNDS = 7;

const rom = new Uint8Array(await Bun.file("web/games/snek.ch8").arrayBuffer());

for (const name of ["zig", "rust"]) {
  const path = `web/${name}.wasm`;
  if (!(await Bun.file(path).exists())) throw new Error(`${path} is missing, run bun run build:${name}`);
  const core = (await WebAssembly.instantiate(await Bun.file(path).arrayBuffer(), {})).instance.exports;
  new Uint8Array(core.memory.buffer, core.rom_ptr(), rom.length).set(rom);
  core.load_rom(rom.length, 1, OCTO);
  core.step(STEPS);

  const rates = [];
  for (let i = 0; i < ROUNDS; i++) {
    const start = performance.now();
    core.step(STEPS);
    rates.push(STEPS / ((performance.now() - start) / 1000) / 1e6);
  }
  if (core.is_stopped()) throw new Error(`${name}: the machine stopped, so the rate means nothing`);
  rates.sort((a, b) => a - b);
  console.log(`${name}: ${rates[ROUNDS >> 1].toFixed(0)} million instructions per second (median of ${ROUNDS}, range ${rates[0].toFixed(0)} to ${rates[ROUNDS - 1].toFixed(0)})`);
}
