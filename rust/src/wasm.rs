use std::cell::RefCell;

use crate::{Chip8, MEMORY_SIZE, PROGRAM_START};

const ROM_CAPACITY: usize = MEMORY_SIZE - PROGRAM_START;

struct State {
    machine: Chip8,
    rom_buffer: [u8; ROM_CAPACITY],
    stopped: bool,
}

thread_local! {
    static STATE: RefCell<State> = RefCell::new(State {
        machine: Chip8::init(0),
        rom_buffer: [0; ROM_CAPACITY],
        stopped: false,
    });
}

fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> R {
    STATE.with_borrow_mut(f)
}

#[unsafe(no_mangle)]
pub extern "C" fn rom_ptr() -> u32 {
    with_state(|s| s.rom_buffer.as_ptr() as u32)
}

#[unsafe(no_mangle)]
pub extern "C" fn load_rom(len: u32, seed: u32) -> u32 {
    with_state(|s| {
        let Some(rom) = s.rom_buffer.get(..len as usize) else {
            return 1;
        };
        s.machine.load_rom(rom, seed.into()).unwrap();
        s.stopped = false;
        0
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn step(n: u32) {
    with_state(|s| {
        for _ in 0..n {
            if s.stopped {
                return;
            }
            let draws = s.machine.memory[s.machine.pc as usize] >> 4 == 0xD;
            if s.machine.step().is_err() {
                s.stopped = true;
                return;
            }
            if draws {
                return;
            }
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn tick_timers() {
    with_state(|s| s.machine.tick_timers());
}

#[unsafe(no_mangle)]
pub extern "C" fn key_down(k: u32) {
    with_state(|s| {
        if let Some(key) = s.machine.keys.get_mut(k as usize) {
            *key = true;
        }
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn key_up(k: u32) {
    with_state(|s| {
        if let Some(key) = s.machine.keys.get_mut(k as usize) {
            *key = false;
        }
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn framebuffer_ptr() -> u32 {
    with_state(|s| s.machine.display.as_ptr() as u32)
}

#[unsafe(no_mangle)]
pub extern "C" fn sound_on() -> u32 {
    with_state(|s| (s.machine.sound_timer > 0).into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn load(rom: &[u8]) {
        with_state(|s| s.rom_buffer[..rom.len()].copy_from_slice(rom));
        assert_eq!(load_rom(rom.len() as u32, 0), 0);
    }

    #[test]
    fn load_rom_rejects_a_rom_that_is_too_long_and_accepts_one_that_just_fits() {
        assert_eq!(load_rom(ROM_CAPACITY as u32 + 1, 0), 1);
        assert_eq!(load_rom(ROM_CAPACITY as u32, 0), 0);
    }

    #[test]
    fn step_runs_exactly_n_instructions() {
        load(&[0x61, 0x01, 0x62, 0x02, 0x63, 0x03]);
        step(2);
        assert_eq!(with_state(|s| s.machine.pc) as usize, PROGRAM_START + 4);
        assert_eq!(with_state(|s| s.machine.v[3]), 0);
    }

    #[test]
    fn step_returns_right_after_dxyn() {
        load(&[0xA0, 0x50, 0xD0, 0x05, 0x61, 0x01]);
        step(10);
        assert_eq!(with_state(|s| s.machine.pc) as usize, PROGRAM_START + 4);
        assert_eq!(with_state(|s| s.machine.v[1]), 0);
        step(10);
        assert_eq!(with_state(|s| s.machine.v[1]), 1);
    }

    #[test]
    fn an_error_stops_the_machine_until_the_next_load_rom() {
        load(&[0x01, 0x23]);
        step(1);
        assert!(with_state(|s| s.stopped));
        let pc = with_state(|s| s.machine.pc);
        step(1);
        assert_eq!(with_state(|s| s.machine.pc), pc);

        load(&[0x61, 0x01]);
        assert!(!with_state(|s| s.stopped));
        step(1);
        assert_eq!(with_state(|s| s.machine.v[1]), 1);
    }

    #[test]
    fn keys_outside_0x0_to_0xf_are_ignored() {
        key_down(5);
        assert!(with_state(|s| s.machine.keys[5]));
        key_up(5);
        assert!(!with_state(|s| s.machine.keys[5]));
        key_down(16);
        key_up(0xFFFF_FFFF);
    }

    #[test]
    fn sound_on_follows_the_sound_timer() {
        load(&[]);
        assert_eq!(sound_on(), 0);
        with_state(|s| s.machine.sound_timer = 2);
        assert_eq!(sound_on(), 1);
        tick_timers();
        tick_timers();
        assert_eq!(sound_on(), 0);
    }
}
