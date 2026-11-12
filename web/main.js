const WIDTH = 64;
const HEIGHT = 32;
const FRAME_MS = 1000 / 60;
const MAX_STEPS_PER_FRAME = 1000;
const STATS_INTERVAL_MS = 1000;
const MAX_ROM_BYTES = 3584;
const MAX_CATCHUP_MS = 5 * FRAME_MS;
const JITTER_HEADROOM_MS = FRAME_MS / 2;

const KEYS = {
  Digit1: 0x1, Digit2: 0x2, Digit3: 0x3, Digit4: 0xC,
  KeyQ: 0x4, KeyW: 0x5, KeyE: 0x6, KeyR: 0xD,
  KeyA: 0x7, KeyS: 0x8, KeyD: 0x9, KeyF: 0xE,
  KeyZ: 0xA, KeyX: 0x0, KeyC: 0xB, KeyV: 0xF,
};

const coreSelect = document.getElementById("core");
const romInput = document.getElementById("rom");
const speedInput = document.getElementById("speed");
const pauseButton = document.getElementById("pause");
const status = document.getElementById("status");
const stats = document.getElementById("stats");
const ctx = document.getElementById("screen").getContext("2d");
const image = ctx.createImageData(WIDTH, HEIGHT);
const pixels = new Uint32Array(image.data.buffer);

let core = null;
let coreName = null;
let rom = null;
let romName = null;
const held = new Set();
let audio = null;
let paused = false;
let stepsPerFrame = speedInput.valueAsNumber;
let coreBytes = 0;
// Time spent in core.step and core.tick_timers since the last readout.
let busyMs = 0;
let busyFrames = 0;
let statsAt = 0;
let microsPerFrame = null;

function showStats() {
  const time = microsPerFrame === null ? "" : `, ${microsPerFrame.toFixed(0)} µs per frame of ${stepsPerFrame} steps`;
  stats.textContent = `${coreName}.wasm is ${coreBytes.toLocaleString("en-US")} bytes${time}`;
}

function resetStats() {
  busyMs = 0;
  busyFrames = 0;
  microsPerFrame = null;
  showStats();
}

function setPaused(value) {
  paused = value;
  pauseButton.textContent = paused ? "Resume" : "Pause";
}

async function loadCore(name) {
  try {
    const response = await fetch(`${name}.wasm`);
    if (!response.ok) throw new Error(`${response.status}`);
    const bytes = await response.arrayBuffer();
    core = (await WebAssembly.instantiate(bytes, {})).instance.exports;
    coreName = name;
    coreBytes = bytes.byteLength;
    resetStats();
  } catch (error) {
    status.textContent = `Could not load ${name}.wasm (${error.message}). Did you run bun run build:${name}?`;
    coreSelect.value = coreName ?? name;
    throw error;
  }
}

function startRom() {
  new Uint8Array(core.memory.buffer, core.rom_ptr(), rom.length).set(rom);
  core.load_rom(rom.length, crypto.getRandomValues(new Uint32Array(1))[0]);
  for (const key of held) core.key_down(key);
  setPaused(false);
  status.textContent = `Running ${romName} on the ${coreName} core.`;
}

// AudioContext needs a user gesture.
function startAudio() {
  if (!audio) {
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
  audio.context.resume();
}

function draw() {
  const framebuffer = new Uint8Array(core.memory.buffer, core.framebuffer_ptr(), WIDTH * HEIGHT);
  for (let i = 0; i < framebuffer.length; i++) {
    pixels[i] = framebuffer[i] ? 0xFFFFFFFF : 0xFF000000;
  }
  ctx.putImageData(image, 0, 0);
}

let last = null;
let behind = JITTER_HEADROOM_MS;
function frame(now) {
  requestAnimationFrame(frame);
  behind = Math.min(behind + (last === null ? 0 : now - last), MAX_CATCHUP_MS);
  last = now;
  if (!rom) return;
  if (paused) {
    behind = JITTER_HEADROOM_MS;
    if (audio) audio.gain.gain.value = 0;
    return;
  }
  const start = performance.now();
  while (behind >= FRAME_MS) {
    core.step(stepsPerFrame);
    core.tick_timers();
    behind -= FRAME_MS;
    busyFrames++;
  }
  busyMs += performance.now() - start;
  // One frame is far below the browser's timer resolution, so only the average over a second means anything.
  if (now - statsAt >= STATS_INTERVAL_MS && busyFrames > 0) {
    microsPerFrame = (busyMs / busyFrames) * 1000;
    busyMs = 0;
    busyFrames = 0;
    statsAt = now;
    showStats();
  }
  draw();
  if (audio) audio.gain.gain.value = core.sound_on() ? 0.05 : 0;
}

await loadCore(coreSelect.value);
romInput.disabled = false;
requestAnimationFrame(frame);

romInput.addEventListener("change", async () => {
  const file = romInput.files[0];
  // Clearing the input lets the same file be picked again to restart it.
  romInput.value = "";
  if (!file) return;
  const bytes = new Uint8Array(await file.arrayBuffer());
  if (bytes.length > MAX_ROM_BYTES) {
    status.textContent = `${file.name} is ${bytes.length} bytes. The limit is ${MAX_ROM_BYTES}.`;
    return;
  }
  rom = bytes;
  romName = file.name;
  startAudio();
  startRom();
});

speedInput.addEventListener("change", () => {
  const steps = Math.round(speedInput.valueAsNumber);
  if (steps >= 1) stepsPerFrame = Math.min(steps, MAX_STEPS_PER_FRAME);
  speedInput.value = stepsPerFrame;
  resetStats();
});

pauseButton.addEventListener("click", () => setPaused(!paused));

coreSelect.addEventListener("change", async () => {
  try {
    await loadCore(coreSelect.value);
  } catch {
    return;
  }
  if (rom) startRom();
});

addEventListener("keydown", (e) => {
  // Let the speed field take digits.
  if (e.target === speedInput || e.ctrlKey || e.metaKey || e.altKey) return;
  if (e.code === "KeyP") {
    if (!e.repeat) setPaused(!paused);
    return;
  }
  const key = KEYS[e.code];
  if (key === undefined) return;
  e.preventDefault();
  if (audio) audio.context.resume();
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
