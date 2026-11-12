//! The CHIP-8 machine: memory, registers, screen, and the instructions that change them.

mod wasm;

pub const MEMORY_SIZE: usize = 4096;
pub const PROGRAM_START: usize = 0x200;
pub const FONT_START: usize = 0x50;
pub const WIDTH: usize = 64;
pub const HEIGHT: usize = 32;

const FONT: [u8; 80] = [
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
];

const ADDRESS_MASK: u16 = 0xFFF;

#[derive(Debug, PartialEq)]
pub struct RomTooLarge;

#[derive(Debug, PartialEq)]
pub enum StepError {
    UnknownOpcode,
    StackOverflow,
    StackUnderflow,
}

/// xoshiro256++, seeded through SplitMix64 like Zig's `std.Random.Xoshiro256` (SPEC.md).
pub struct Xoshiro256 {
    s: [u64; 4],
}

impl Xoshiro256 {
    pub fn init(seed: u64) -> Xoshiro256 {
        let mut split_mix = seed;
        let mut s = [0; 4];
        for word in &mut s {
            split_mix = split_mix.wrapping_add(0x9e3779b97f4a7c15);
            let mut z = split_mix;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
            *word = z ^ (z >> 31);
        }
        Xoshiro256 { s }
    }

    pub fn next_u64(&mut self) -> u64 {
        let s = &mut self.s;
        let result = s[0].wrapping_add(s[3]).rotate_left(23).wrapping_add(s[0]);
        let t = s[1] << 17;
        s[2] ^= s[0];
        s[3] ^= s[1];
        s[1] ^= s[2];
        s[0] ^= s[3];
        s[2] ^= t;
        s[3] = s[3].rotate_left(45);
        result
    }
}

pub struct Chip8 {
    pub memory: [u8; MEMORY_SIZE],
    pub v: [u8; 16],
    pub i: u16,
    pub pc: u16,
    pub stack: [u16; 16],
    pub sp: u8,
    pub delay_timer: u8,
    pub sound_timer: u8,
    pub display: [u8; WIDTH * HEIGHT],
    pub keys: [bool; 16],
    pub rng: Xoshiro256,
    /// While FX0A waits, the key that went down. FX0A finishes when it comes back up.
    pub held_key: Option<u8>,
}

impl Chip8 {
    pub fn init(seed: u64) -> Chip8 {
        let mut c = Chip8 {
            memory: [0; MEMORY_SIZE],
            v: [0; 16],
            i: 0,
            pc: PROGRAM_START as u16,
            stack: [0; 16],
            sp: 0,
            delay_timer: 0,
            sound_timer: 0,
            display: [0; WIDTH * HEIGHT],
            keys: [false; 16],
            rng: Xoshiro256::init(seed),
            held_key: None,
        };
        c.memory[FONT_START..][..FONT.len()].copy_from_slice(&FONT);
        c
    }

    /// Resets the machine and copies `rom` to 0x200. On error the machine is left as it was.
    pub fn load_rom(&mut self, rom: &[u8], seed: u64) -> Result<(), RomTooLarge> {
        if rom.len() > MEMORY_SIZE - PROGRAM_START {
            return Err(RomTooLarge);
        }
        *self = Chip8::init(seed);
        self.memory[PROGRAM_START..][..rom.len()].copy_from_slice(rom);
        Ok(())
    }

    /// Counts the delay and sound timers down by one, stopping at 0. The host calls it 60 times a second.
    pub fn tick_timers(&mut self) {
        self.delay_timer = self.delay_timer.saturating_sub(1);
        self.sound_timer = self.sound_timer.saturating_sub(1);
    }

    pub fn step(&mut self) -> Result<(), StepError> {
        // Fetch
        let hi = self.memory[self.pc as usize];
        let lo = self.memory[((self.pc + 1) & ADDRESS_MASK) as usize];
        let opcode = (hi as u16) << 8 | lo as u16;
        self.pc = (self.pc + 2) & ADDRESS_MASK;

        // Decode
        let op = opcode >> 12;
        let x = (opcode >> 8 & 0xF) as usize;
        let y = (opcode >> 4 & 0xF) as usize;
        let n = (opcode & 0xF) as u8;
        let nn = opcode as u8;
        let nnn = opcode & ADDRESS_MASK;

        // Execute
        match op {
            0x0 => match opcode {
                0x00E0 => self.display.fill(0),
                0x00EE => {
                    if self.sp == 0 {
                        return Err(StepError::StackUnderflow);
                    }
                    self.sp -= 1;
                    self.pc = self.stack[self.sp as usize];
                }
                _ => return Err(StepError::UnknownOpcode),
            },
            0x1 => self.pc = nnn,
            0x2 => {
                if self.sp as usize == self.stack.len() {
                    return Err(StepError::StackOverflow);
                }
                self.stack[self.sp as usize] = self.pc;
                self.sp += 1;
                self.pc = nnn;
            }
            0x3 => {
                if self.v[x] == nn {
                    self.skip()
                }
            }
            0x4 => {
                if self.v[x] != nn {
                    self.skip()
                }
            }
            0x5 => {
                if self.v[x] == self.v[y] {
                    self.skip()
                }
            }
            0x6 => self.v[x] = nn,
            0x7 => self.v[x] = self.v[x].wrapping_add(nn),
            0x8 => match n {
                0x0 => self.v[x] = self.v[y],
                // COSMAC VIP quirk: the logic ops reset VF (SPEC.md).
                0x1 => {
                    self.v[x] |= self.v[y];
                    self.v[0xF] = 0;
                }
                0x2 => {
                    self.v[x] &= self.v[y];
                    self.v[0xF] = 0;
                }
                0x3 => {
                    self.v[x] ^= self.v[y];
                    self.v[0xF] = 0;
                }
                0x4 => {
                    let (sum, carry) = self.v[x].overflowing_add(self.v[y]);
                    self.v[x] = sum;
                    self.v[0xF] = carry as u8;
                }
                0x5 => {
                    let (difference, borrow) = self.v[x].overflowing_sub(self.v[y]);
                    self.v[x] = difference;
                    self.v[0xF] = !borrow as u8;
                }
                0x6 => {
                    let shifted_out = self.v[y] & 1;
                    self.v[x] = self.v[y] >> 1;
                    self.v[0xF] = shifted_out;
                }
                0x7 => {
                    let (difference, borrow) = self.v[y].overflowing_sub(self.v[x]);
                    self.v[x] = difference;
                    self.v[0xF] = !borrow as u8;
                }
                0xE => {
                    let shifted_out = self.v[y] >> 7;
                    self.v[x] = self.v[y] << 1;
                    self.v[0xF] = shifted_out;
                }
                _ => return Err(StepError::UnknownOpcode),
            },
            0x9 => {
                if self.v[x] != self.v[y] {
                    self.skip()
                }
            }
            0xA => self.i = nnn,
            0xB => self.pc = (nnn + self.v[0] as u16) & ADDRESS_MASK,
            0xC => self.v[x] = self.rng.next_u64() as u8 & nn,
            0xD => self.draw(x, y, n),
            0xE => {
                // Only the low 4 bits of VX name a key.
                let pressed = self.keys[(self.v[x] & 0xF) as usize];
                match nn {
                    0x9E => {
                        if pressed {
                            self.skip()
                        }
                    }
                    0xA1 => {
                        if !pressed {
                            self.skip()
                        }
                    }
                    _ => return Err(StepError::UnknownOpcode),
                }
            }
            0xF => match nn {
                0x07 => self.v[x] = self.delay_timer,
                0x0A => self.wait_for_key(x),
                0x15 => self.delay_timer = self.v[x],
                0x18 => self.sound_timer = self.v[x],
                0x1E => self.i = (self.i + self.v[x] as u16) & ADDRESS_MASK,
                0x29 => self.i = FONT_START as u16 + (self.v[x] & 0xF) as u16 * 5,
                0x33 => {
                    let value = self.v[x];
                    self.memory[self.i as usize] = value / 100;
                    self.memory[((self.i + 1) & ADDRESS_MASK) as usize] = value / 10 % 10;
                    self.memory[((self.i + 2) & ADDRESS_MASK) as usize] = value % 10;
                }
                // Like the COSMAC VIP, these move I one step per register, so I ends at I + X + 1.
                0x55 => {
                    for &register in &self.v[..=x] {
                        self.memory[self.i as usize] = register;
                        self.i = (self.i + 1) & ADDRESS_MASK;
                    }
                }
                0x65 => {
                    for register in &mut self.v[..=x] {
                        *register = self.memory[self.i as usize];
                        self.i = (self.i + 1) & ADDRESS_MASK;
                    }
                }
                _ => return Err(StepError::UnknownOpcode),
            },
            _ => unreachable!("op is 4 bits"),
        }
        Ok(())
    }

    /// FX0A: waits for a key to go down and come back up, then stores it in VX.
    /// Waiting means moving pc back, so the same instruction runs again next step.
    fn wait_for_key(&mut self, x: usize) {
        if let Some(key) = self.held_key {
            if !self.keys[key as usize] {
                self.v[x] = key;
                self.held_key = None;
                return;
            }
        } else if let Some(key) = self.keys.iter().position(|&pressed| pressed) {
            self.held_key = Some(key as u8);
        }
        self.pc = self.pc.wrapping_sub(2) & ADDRESS_MASK;
    }

    fn draw(&mut self, x: usize, y: usize, n: u8) {
        let start_x = self.v[x] as usize % WIDTH;
        let start_y = self.v[y] as usize % HEIGHT;
        self.v[0xF] = 0;

        for row in 0..n as usize {
            let py = start_y + row;
            if py >= HEIGHT {
                break;
            }
            let sprite = self.memory[((self.i + row as u16) & ADDRESS_MASK) as usize];

            for col in 0..8 {
                let px = start_x + col;
                if px >= WIDTH {
                    break;
                }
                if sprite & (0x80 >> col) == 0 {
                    continue;
                }

                let pixel = &mut self.display[py * WIDTH + px];
                if *pixel == 1 {
                    self.v[0xF] = 1;
                }
                *pixel ^= 1;
            }
        }
    }

    fn skip(&mut self) {
        self.pc = (self.pc + 2) & ADDRESS_MASK;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine_with(rom: &[u8]) -> Chip8 {
        let mut c = Chip8::init(0);
        c.load_rom(rom, 0).unwrap();
        c
    }

    #[test]
    fn init_puts_the_font_at_0x50_and_starts_at_0x200() {
        let c = Chip8::init(0);
        assert_eq!(c.memory[FONT_START], 0xF0);
        assert_eq!(c.memory[FONT_START + FONT.len() - 1], 0x80);
        assert_eq!(c.pc as usize, PROGRAM_START);
    }

    #[test]
    fn load_rom_copies_the_rom_to_0x200() {
        let mut c = Chip8::init(0);
        c.load_rom(&[0x12, 0x34], 0).unwrap();
        assert_eq!(c.memory[PROGRAM_START..][..2], [0x12, 0x34]);
    }

    #[test]
    fn load_rom_resets_the_machine_before_loading() {
        let mut c = machine_with(&[0x6A, 0x05, 0x12, 0x34]);
        c.step().unwrap();
        c.display[0] = 1;

        c.load_rom(&[0x00, 0xE0], 0).unwrap();
        assert_eq!(c.v[0xA], 0);
        assert_eq!(c.pc as usize, PROGRAM_START);
        assert_eq!(c.display[0], 0);
        // The old ROM was longer, and its tail must not survive.
        assert_eq!(c.memory[PROGRAM_START + 2], 0);
        assert_eq!(c.memory[FONT_START], 0xF0);
    }

    #[test]
    fn load_rom_rejects_a_rom_that_doesnt_fit_and_keeps_the_old_one() {
        let mut c = machine_with(&[0x12, 0x34]);
        let too_big = [0; MEMORY_SIZE - PROGRAM_START + 1];
        assert_eq!(c.load_rom(&too_big, 0), Err(RomTooLarge));
        assert_eq!(c.memory[PROGRAM_START], 0x12);
    }

    #[test]
    fn op_6xnn_sets_vx() {
        let mut c = machine_with(&[0x6A, 0x05]);
        c.step().unwrap();
        assert_eq!(c.v[0xA], 5);
        assert_eq!(c.pc, 0x202);
    }

    #[test]
    fn op_7xnn_adds_to_vx_wraps_and_leaves_vf_alone() {
        let mut c = machine_with(&[0x60, 0xFF, 0x70, 0x02]);
        c.step().unwrap();
        c.step().unwrap();
        assert_eq!(c.v[0], 1);
        assert_eq!(c.v[0xF], 0);
    }

    #[test]
    fn op_1nnn_jumps() {
        let mut c = machine_with(&[0x12, 0x34]);
        c.step().unwrap();
        assert_eq!(c.pc, 0x234);
    }

    #[test]
    fn annn_sets_i() {
        let mut c = machine_with(&[0xA1, 0x23]);
        c.step().unwrap();
        assert_eq!(c.i, 0x123);
    }

    #[test]
    fn op_00e0_clears_the_screen() {
        let mut c = machine_with(&[0x00, 0xE0]);
        c.display[5] = 1;
        c.step().unwrap();
        assert!(c.display.iter().all(|&p| p == 0));
    }

    #[test]
    fn dxyn_draws_a_sprite_and_drawing_it_again_erases_it_and_sets_vf() {
        // I = font "0", then draw it twice at (V0, V0) = (0, 0)
        let mut c = machine_with(&[0xA0, 0x50, 0xD0, 0x05, 0xD0, 0x05]);
        c.step().unwrap();
        c.step().unwrap();
        assert_eq!(c.display[..5], [1, 1, 1, 1, 0]);
        assert_eq!(c.display[WIDTH..][..5], [1, 0, 0, 1, 0]);
        assert_eq!(c.v[0xF], 0);

        c.step().unwrap();
        assert!(c.display.iter().all(|&p| p == 0));
        assert_eq!(c.v[0xF], 1);
    }

    #[test]
    fn dxyn_reads_vf_as_a_coordinate_before_resetting_it() {
        // VF = 10, then draw the top row of font "0" at (VF, VF)
        let mut c = machine_with(&[0x6F, 10, 0xA0, 0x50, 0xDF, 0xF1]);
        run_steps(&mut c, 3);
        assert_eq!(c.display[10 * WIDTH + 10], 1);
        assert_eq!(c.v[0xF], 0);
    }

    #[test]
    fn dxyn_clips_at_the_right_and_bottom_edges() {
        // V0 = 62, so x = 62 and y = 62 % 32 = 30
        let mut c = machine_with(&[0x60, 62, 0xA0, 0x50, 0xD0, 0x05]);
        run_steps(&mut c, 3);
        assert_eq!(c.display[30 * WIDTH + 62], 1);
        assert_eq!(c.display[30 * WIDTH + 63], 1);
        assert_eq!(c.display[31 * WIDTH + 62], 1);
        assert_eq!(c.display[30 * WIDTH], 0);
        assert_eq!(c.display[62], 0);
    }

    #[test]
    fn unknown_opcodes_return_an_error() {
        let mut c = machine_with(&[0x01, 0x23]);
        assert_eq!(c.step(), Err(StepError::UnknownOpcode));
    }

    // The other instructions. The behavior follows the COSMAC VIP, as SPEC.md describes.

    fn run_steps(c: &mut Chip8, count: usize) {
        for _ in 0..count {
            c.step().unwrap();
        }
    }

    // Skips. A skip moves pc past one more instruction, so 2 extra bytes.

    #[test]
    fn op_3xnn_skips_when_vx_equals_nn() {
        let mut equal = machine_with(&[0x60, 0x05, 0x30, 0x05]);
        run_steps(&mut equal, 2);
        assert_eq!(equal.pc, 0x206);

        let mut different = machine_with(&[0x60, 0x05, 0x30, 0x06]);
        run_steps(&mut different, 2);
        assert_eq!(different.pc, 0x204);
    }

    #[test]
    fn op_4xnn_skips_when_vx_differs_from_nn() {
        let mut different = machine_with(&[0x60, 0x05, 0x40, 0x06]);
        run_steps(&mut different, 2);
        assert_eq!(different.pc, 0x206);

        let mut equal = machine_with(&[0x60, 0x05, 0x40, 0x05]);
        run_steps(&mut equal, 2);
        assert_eq!(equal.pc, 0x204);
    }

    #[test]
    fn op_5xy0_skips_when_vx_equals_vy() {
        let mut equal = machine_with(&[0x60, 0x05, 0x61, 0x05, 0x50, 0x10]);
        run_steps(&mut equal, 3);
        assert_eq!(equal.pc, 0x208);

        let mut different = machine_with(&[0x60, 0x05, 0x61, 0x06, 0x50, 0x10]);
        run_steps(&mut different, 3);
        assert_eq!(different.pc, 0x206);
    }

    #[test]
    fn op_9xy0_skips_when_vx_differs_from_vy() {
        let mut different = machine_with(&[0x60, 0x05, 0x61, 0x06, 0x90, 0x10]);
        run_steps(&mut different, 3);
        assert_eq!(different.pc, 0x208);

        let mut equal = machine_with(&[0x60, 0x05, 0x61, 0x05, 0x90, 0x10]);
        run_steps(&mut equal, 3);
        assert_eq!(equal.pc, 0x206);
    }

    // Subroutines

    #[test]
    fn op_2nnn_pushes_the_return_address_and_jumps() {
        let mut c = machine_with(&[0x22, 0x06]);
        c.step().unwrap();
        assert_eq!(c.pc, 0x206);
        assert_eq!(c.sp, 1);
        assert_eq!(c.stack[0], 0x202);
    }

    #[test]
    fn op_00ee_returns_to_the_instruction_after_the_call() {
        // 0x200: call 0x204. 0x204: return.
        let mut c = machine_with(&[0x22, 0x04, 0x00, 0x00, 0x00, 0xEE]);
        run_steps(&mut c, 2);
        assert_eq!(c.pc, 0x202);
        assert_eq!(c.sp, 0);
    }

    #[test]
    fn a_17th_nested_call_is_a_stack_overflow() {
        // 0x200 calls itself, so every step pushes one more address.
        let mut c = machine_with(&[0x22, 0x00]);
        run_steps(&mut c, 16);
        assert_eq!(c.step(), Err(StepError::StackOverflow));
    }

    #[test]
    fn op_00ee_with_an_empty_stack_is_a_stack_underflow() {
        let mut c = machine_with(&[0x00, 0xEE]);
        assert_eq!(c.step(), Err(StepError::StackUnderflow));
    }

    // Arithmetic. Each ROM sets VF first, so a test notices when VF isn't written.

    #[test]
    fn op_8xy0_copies_vy_into_vx() {
        let mut c = machine_with(&[0x61, 0x07, 0x80, 0x10]);
        run_steps(&mut c, 2);
        assert_eq!(c.v[0], 7);
    }

    #[test]
    fn op_8xy1_ors_and_resets_vf() {
        let mut c = machine_with(&[0x6F, 0x01, 0x60, 0x0F, 0x61, 0xF0, 0x80, 0x11]);
        run_steps(&mut c, 4);
        assert_eq!(c.v[0], 0xFF);
        assert_eq!(c.v[0xF], 0);
    }

    #[test]
    fn op_8xy2_ands_and_resets_vf() {
        let mut c = machine_with(&[0x6F, 0x01, 0x60, 0x0F, 0x61, 0x3C, 0x80, 0x12]);
        run_steps(&mut c, 4);
        assert_eq!(c.v[0], 0x0C);
        assert_eq!(c.v[0xF], 0);
    }

    #[test]
    fn op_8xy3_xors_and_resets_vf() {
        let mut c = machine_with(&[0x6F, 0x01, 0x60, 0x0F, 0x61, 0x3C, 0x80, 0x13]);
        run_steps(&mut c, 4);
        assert_eq!(c.v[0], 0x33);
        assert_eq!(c.v[0xF], 0);
    }

    #[test]
    fn op_8xy4_adds_and_sets_vf_to_the_carry() {
        let mut carry = machine_with(&[0x6F, 0x00, 0x60, 0xFF, 0x61, 0x02, 0x80, 0x14]);
        run_steps(&mut carry, 4);
        assert_eq!(carry.v[0], 0x01);
        assert_eq!(carry.v[0xF], 1);

        let mut no_carry = machine_with(&[0x6F, 0x01, 0x60, 0x01, 0x61, 0x02, 0x80, 0x14]);
        run_steps(&mut no_carry, 4);
        assert_eq!(no_carry.v[0], 0x03);
        assert_eq!(no_carry.v[0xF], 0);
    }

    #[test]
    fn op_8xy5_subtracts_vy_from_vx_and_sets_vf_to_1_when_theres_no_borrow() {
        let mut no_borrow = machine_with(&[0x6F, 0x00, 0x60, 0x05, 0x61, 0x03, 0x80, 0x15]);
        run_steps(&mut no_borrow, 4);
        assert_eq!(no_borrow.v[0], 0x02);
        assert_eq!(no_borrow.v[0xF], 1);

        let mut borrow = machine_with(&[0x6F, 0x01, 0x60, 0x03, 0x61, 0x05, 0x80, 0x15]);
        run_steps(&mut borrow, 4);
        assert_eq!(borrow.v[0], 0xFE);
        assert_eq!(borrow.v[0xF], 0);

        // Equal values don't borrow, so VF is 1 here too.
        let mut equal = machine_with(&[0x6F, 0x00, 0x60, 0x05, 0x61, 0x05, 0x80, 0x15]);
        run_steps(&mut equal, 4);
        assert_eq!(equal.v[0], 0x00);
        assert_eq!(equal.v[0xF], 1);
    }

    #[test]
    fn op_8xy6_shifts_vy_right_into_vx_and_sets_vf_to_the_bit_shifted_out() {
        let mut c = machine_with(&[0x6F, 0x00, 0x60, 0x00, 0x61, 0x05, 0x80, 0x16]);
        run_steps(&mut c, 4);
        assert_eq!(c.v[0], 0x02);
        assert_eq!(c.v[0xF], 1);
        assert_eq!(c.v[1], 0x05);
    }

    #[test]
    fn op_8xy6_and_8xye_still_set_vf_right_when_x_and_y_are_the_same_register() {
        // V1 = 5, then 8116: V1 = 5 >> 1 = 2, and the bit shifted out is 1
        let mut right = machine_with(&[0x61, 0x05, 0x81, 0x16]);
        run_steps(&mut right, 2);
        assert_eq!(right.v[1], 0x02);
        assert_eq!(right.v[0xF], 1);

        // V1 = 0x81, then 811E: V1 = 0x02, and the bit shifted out is 1
        let mut left = machine_with(&[0x61, 0x81, 0x81, 0x1E]);
        run_steps(&mut left, 2);
        assert_eq!(left.v[1], 0x02);
        assert_eq!(left.v[0xF], 1);
    }

    #[test]
    fn op_8xy7_subtracts_vx_from_vy_and_sets_vf_to_1_when_theres_no_borrow() {
        let mut no_borrow = machine_with(&[0x6F, 0x00, 0x60, 0x03, 0x61, 0x05, 0x80, 0x17]);
        run_steps(&mut no_borrow, 4);
        assert_eq!(no_borrow.v[0], 0x02);
        assert_eq!(no_borrow.v[0xF], 1);

        let mut borrow = machine_with(&[0x6F, 0x01, 0x60, 0x05, 0x61, 0x03, 0x80, 0x17]);
        run_steps(&mut borrow, 4);
        assert_eq!(borrow.v[0], 0xFE);
        assert_eq!(borrow.v[0xF], 0);
    }

    #[test]
    fn op_8xye_shifts_vy_left_into_vx_and_sets_vf_to_the_bit_shifted_out() {
        let mut c = machine_with(&[0x6F, 0x00, 0x60, 0x00, 0x61, 0x81, 0x80, 0x1E]);
        run_steps(&mut c, 4);
        assert_eq!(c.v[0], 0x02);
        assert_eq!(c.v[0xF], 1);
        assert_eq!(c.v[1], 0x81);
    }

    #[test]
    fn when_x_is_f_the_flag_overwrites_the_result() {
        // VF = 0xFF + 3 would be 0x02, but the carry is written last.
        let mut add = machine_with(&[0x6F, 0xFF, 0x61, 0x03, 0x8F, 0x14]);
        run_steps(&mut add, 3);
        assert_eq!(add.v[0xF], 1);

        // VF = 5 - 3 would be 0x02, but "no borrow" is written last.
        let mut sub = machine_with(&[0x6F, 0x05, 0x61, 0x03, 0x8F, 0x15]);
        run_steps(&mut sub, 3);
        assert_eq!(sub.v[0xF], 1);

        // VF = 4 >> 1 would be 0x02, but the shifted-out bit is 0.
        let mut shift = machine_with(&[0x61, 0x04, 0x8F, 0x16]);
        run_steps(&mut shift, 2);
        assert_eq!(shift.v[0xF], 0);

        // VF = 5 - 3 (V1 - VF) would be 0x02, but "no borrow" is written last.
        let mut reverse_sub = machine_with(&[0x6F, 0x03, 0x61, 0x05, 0x8F, 0x17]);
        run_steps(&mut reverse_sub, 3);
        assert_eq!(reverse_sub.v[0xF], 1);
    }

    // Memory

    #[test]
    fn bnnn_jumps_to_nnn_plus_v0() {
        let mut c = machine_with(&[0x60, 0x04, 0xB3, 0x00]);
        run_steps(&mut c, 2);
        assert_eq!(c.pc, 0x304);
    }

    #[test]
    fn fx1e_adds_vx_to_i() {
        let mut c = machine_with(&[0xA1, 0x00, 0x60, 0x05, 0xF0, 0x1E]);
        run_steps(&mut c, 3);
        assert_eq!(c.i, 0x105);
    }

    #[test]
    fn fx29_points_i_at_the_font_character_for_vx() {
        let mut c = machine_with(&[0x60, 0x0A, 0xF0, 0x29]);
        run_steps(&mut c, 2);
        assert_eq!(c.i as usize, FONT_START + 0xA * 5);
    }

    #[test]
    fn fx33_stores_the_decimal_digits_of_vx_at_i() {
        let mut c = machine_with(&[0x60, 234, 0xA3, 0x00, 0xF0, 0x33]);
        run_steps(&mut c, 3);
        assert_eq!(c.memory[0x300..][..3], [2, 3, 4]);
    }

    #[test]
    fn fx55_stores_v0_through_vx_at_i_and_moves_i_past_them() {
        let mut c = machine_with(&[0x60, 1, 0x61, 2, 0x62, 3, 0x63, 4, 0xA3, 0x00, 0xF2, 0x55]);
        run_steps(&mut c, 6);
        assert_eq!(c.memory[0x300..][..4], [1, 2, 3, 0]);
        assert_eq!(c.i, 0x303);
    }

    #[test]
    fn fx65_loads_v0_through_vx_from_i_and_moves_i_past_them() {
        let mut c = machine_with(&[0xA3, 0x00, 0xF2, 0x65]);
        c.memory[0x300..][..4].copy_from_slice(&[7, 8, 9, 10]);
        run_steps(&mut c, 2);
        assert_eq!(c.v[..4], [7, 8, 9, 0]);
        assert_eq!(c.i, 0x303);
    }

    // Timers and random

    #[test]
    fn fx15_sets_the_delay_timer() {
        let mut c = machine_with(&[0x60, 60, 0xF0, 0x15]);
        run_steps(&mut c, 2);
        assert_eq!(c.delay_timer, 60);
    }

    #[test]
    fn fx18_sets_the_sound_timer() {
        let mut c = machine_with(&[0x60, 60, 0xF0, 0x18]);
        run_steps(&mut c, 2);
        assert_eq!(c.sound_timer, 60);
    }

    #[test]
    fn fx07_reads_the_delay_timer_into_vx() {
        let mut c = machine_with(&[0xF0, 0x07]);
        c.delay_timer = 42;
        c.step().unwrap();
        assert_eq!(c.v[0], 42);
    }

    #[test]
    fn tick_timers_counts_both_timers_down_and_stops_at_0() {
        let mut c = Chip8::init(0);
        c.delay_timer = 2;
        c.sound_timer = 1;
        c.tick_timers();
        assert_eq!(c.delay_timer, 1);
        assert_eq!(c.sound_timer, 0);
        c.tick_timers();
        assert_eq!(c.delay_timer, 0);
        assert_eq!(c.sound_timer, 0);
    }

    #[test]
    fn cxnn_masks_a_random_byte_with_nn() {
        for seed in 0..32 {
            let mut c = Chip8::init(0);
            c.load_rom(&[0xC0, 0x0F], seed).unwrap();
            c.step().unwrap();
            assert_eq!(c.v[0] & 0xF0, 0);
        }
    }

    #[test]
    fn cxnn_gives_the_same_numbers_for_the_same_seed() {
        let mut a = Chip8::init(0);
        let mut b = Chip8::init(0);
        a.load_rom(&[0xC0, 0xFF], 7).unwrap();
        b.load_rom(&[0xC0, 0xFF], 7).unwrap();
        a.step().unwrap();
        b.step().unwrap();
        assert_eq!(a.v[0], b.v[0]);
    }

    #[test]
    fn cxnn_takes_the_low_byte_of_each_xoshiro256_output() {
        let mut c = machine_with(&[0xC0, 0xFF, 0xC1, 0xFF]);
        run_steps(&mut c, 2);
        let seed_0_outputs: [u64; 2] = [0x53175d61490b23df, 0x61da6f3dc380d507];
        assert_eq!(c.v[..2], seed_0_outputs.map(|output| output as u8));
    }

    // Input

    #[test]
    fn ex9e_skips_when_the_key_in_vx_is_pressed() {
        let mut pressed = machine_with(&[0x60, 0x05, 0xE0, 0x9E]);
        pressed.keys[5] = true;
        run_steps(&mut pressed, 2);
        assert_eq!(pressed.pc, 0x206);

        let mut released = machine_with(&[0x60, 0x05, 0xE0, 0x9E]);
        run_steps(&mut released, 2);
        assert_eq!(released.pc, 0x204);
    }

    #[test]
    fn exa1_skips_when_the_key_in_vx_is_not_pressed() {
        let mut released = machine_with(&[0x60, 0x05, 0xE0, 0xA1]);
        run_steps(&mut released, 2);
        assert_eq!(released.pc, 0x206);

        let mut pressed = machine_with(&[0x60, 0x05, 0xE0, 0xA1]);
        pressed.keys[5] = true;
        run_steps(&mut pressed, 2);
        assert_eq!(pressed.pc, 0x204);
    }

    #[test]
    fn fx0a_waits_until_a_key_is_pressed_and_released_then_stores_it_in_vx() {
        let mut c = machine_with(&[0xF0, 0x0A]);

        c.step().unwrap();
        assert_eq!(c.pc, 0x200);

        c.keys[7] = true;
        c.step().unwrap();
        assert_eq!(c.pc, 0x200);

        c.keys[7] = false;
        c.step().unwrap();
        assert_eq!(c.v[0], 7);
        assert_eq!(c.pc, 0x202);
    }

    #[test]
    fn addresses_wrap_from_0xfff_to_0x000() {
        // V0..V2 = 1, 2, 3, I = 0xFFE, then FX55 stores across the end of memory.
        let mut c = machine_with(&[0x60, 1, 0x61, 2, 0x62, 3, 0xAF, 0xFE, 0xF2, 0x55]);
        run_steps(&mut c, 5);
        assert_eq!(c.memory[0xFFE..], [1, 2]);
        assert_eq!(c.memory[0x000], 3);
        assert_eq!(c.i, 0x001);

        // An instruction at 0xFFF has its second byte at 0x000.
        c.pc = 0xFFF;
        c.memory[0xFFF] = 0x6B;
        c.memory[0x000] = 0x07;
        c.step().unwrap();
        assert_eq!(c.v[0xB], 7);
        assert_eq!(c.pc, 0x001);
    }
}
