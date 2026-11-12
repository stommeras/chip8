const WIDTH = 64;
const HEIGHT = 32;
const FRAME_MS = 1000 / 60;
const STEPS_PER_FRAME = 11;

// Keyboard position to CHIP-8 key, so it works on any layout.
const KEYS = {
  Digit1: 0x1, Digit2: 0x2, Digit3: 0x3, Digit4: 0xC,
  KeyQ: 0x4, KeyW: 0x5, KeyE: 0x6, KeyR: 0xD,
  KeyA: 0x7, KeyS: 0x8, KeyD: 0x9, KeyF: 0xE,
  KeyZ: 0xA, KeyX: 0x0, KeyC: 0xB, KeyV: 0xF,
};

const coreSelect = document.getElementById("core");
const romInput = document.getElementById("rom");
const status = document.getElementById("status");
const ctx = document.getElementById("screen").getContext("2d");
const image = ctx.createImageData(WIDTH, HEIGHT);
const pixels = new Uint32Array(image.data.buffer);

let core = null;
let rom = null;
let held = new Set();
let audio = null;

async function loadCore(name) {
  const bytes = await (await fetch(`${name}.wasm`)).arrayBuffer();
  core = (await WebAssembly.instantiate(bytes, {})).instance.exports;
}

function startRom() {
  if (rom.length > 3584) {
    status.textContent = `${rom.length} bytes is too big. The limit is 3584.`;
    rom = null;
    return;
  }
  // The memory view is made after every call that could move it.
  new Uint8Array(core.memory.buffer, core.rom_ptr(), rom.length).set(rom);
  core.load_rom(rom.length, crypto.getRandomValues(new Uint32Array(1))[0]);
  for (const k of held) core.key_down(k);
  status.textContent = `Running ${romInput.files[0].name} on the ${coreSelect.value} core.`;
}

// AudioContext needs a user gesture, and picking a ROM is one.
function startAudio() {
  if (audio) return;
  const context = new AudioContext();
  const oscillator = context.createOscillator();
  const gain = context.createGain();
  gain.gain.value = 0;
  oscillator.type = "square";
  oscillator.frequency.value = 440;
  oscillator.connect(gain).connect(context.destination);
  oscillator.start();
  audio = { context, gain };
}

function draw() {
  const framebuffer = new Uint8Array(core.memory.buffer, core.framebuffer_ptr(), WIDTH * HEIGHT);
  for (let i = 0; i < framebuffer.length; i++) {
    pixels[i] = framebuffer[i] ? 0xFFFFFFFF : 0xFF000000;
  }
  ctx.putImageData(image, 0, 0);
}

let last = null;
let behind = 0;
function frame(now) {
  requestAnimationFrame(frame);
  // Count real time, so a 120 Hz display doesn't run the game twice as fast.
  // Capped, so a hidden tab doesn't run a burst of frames when it comes back.
  behind = Math.min(behind + (last === null ? 0 : now - last), 5 * FRAME_MS);
  last = now;
  if (!rom) return;
  while (behind >= FRAME_MS) {
    core.step(STEPS_PER_FRAME);
    core.tick_timers();
    behind -= FRAME_MS;
  }
  draw();
  if (audio) audio.gain.gain.value = core.sound_on() ? 0.05 : 0;
}

await loadCore(coreSelect.value);
requestAnimationFrame(frame);

romInput.addEventListener("change", async () => {
  const file = romInput.files[0];
  if (!file) return;
  rom = new Uint8Array(await file.arrayBuffer());
  startAudio();
  startRom();
});

coreSelect.addEventListener("change", async () => {
  await loadCore(coreSelect.value);
  if (rom) startRom();
});

addEventListener("keydown", (e) => {
  const key = KEYS[e.code];
  if (key === undefined || e.ctrlKey || e.metaKey || e.altKey) return;
  e.preventDefault();
  held.add(key);
  core.key_down(key);
});

addEventListener("keyup", (e) => {
  const key = KEYS[e.code];
  if (key === undefined) return;
  held.delete(key);
  core.key_up(key);
});

// A key released while another window has focus never sends keyup.
addEventListener("blur", () => {
  for (const key of held) core.key_up(key);
  held.clear();
});
