//! The CHIP-8 machine: memory, registers, screen, and the instructions that change them.
const std = @import("std");

pub const memory_size = 4096;
pub const program_start = 0x200;
pub const font_start = 0x50;
pub const width = 64;
pub const height = 32;

const font = [80]u8{
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
};

pub const Chip8 = struct {
    memory: [memory_size]u8 = @splat(0),
    v: [16]u8 = @splat(0),
    i: u16 = 0,
    pc: u16 = program_start,
    stack: [16]u16 = @splat(0),
    sp: u8 = 0,
    delay_timer: u8 = 0,
    sound_timer: u8 = 0,
    display: [width * height]u8 = @splat(0),
    keys: [16]bool = @splat(false),
    rng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Chip8 {
        var c: Chip8 = .{ .rng = .init(seed) };
        @memcpy(c.memory[font_start..][0..font.len], &font);
        return c;
    }

    /// Resets the machine and copies `rom` to 0x200. On error the machine is left as it was.
    /// `rom` must not point into the machine's own memory, since the reset clears it first.
    pub fn loadRom(self: *Chip8, rom: []const u8, seed: u64) error{RomTooLarge}!void {
        if (rom.len > memory_size - program_start) return error.RomTooLarge;
        self.* = .init(seed);
        @memcpy(self.memory[program_start..][0..rom.len], rom);
    }

    /// Counts the delay and sound timers down by one, stopping at 0. The host calls it 60 times a second.
    pub fn tickTimers(self: *Chip8) void {
        _ = self; // TODO: replace this with the countdown
    }

    pub fn step(self: *Chip8) error{UnknownOpcode}!void {
        // Fetch
        const hi = self.memory[self.pc];
        const lo = self.memory[(self.pc + 1) & 0xFFF];
        const opcode = (@as(u16, hi) << 8) | lo;
        self.pc = (self.pc + 2) & 0xFFF;

        // Decode
        const op: u4 = @truncate(opcode >> 12);
        const x: u4 = @truncate(opcode >> 8);
        const y: u4 = @truncate(opcode >> 4);
        const n: u4 = @truncate(opcode);
        const nn: u8 = @truncate(opcode);
        const nnn: u12 = @truncate(opcode);

        // Execute
        switch (op) {
            0x0 => switch (opcode) {
                0x00E0 => @memset(&self.display, 0),
                else => return error.UnknownOpcode,
            },
            0x1 => self.pc = nnn,
            0x3 => if (self.v[x] == nn) self.skip(),
            0x4 => if (self.v[x] != nn) self.skip(),
            0x5 => if (self.v[x] == self.v[y]) self.skip(),
            0x6 => self.v[x] = nn,
            0x7 => self.v[x] +%= nn,
            0x9 => if (self.v[x] != self.v[y]) self.skip(),
            0xA => self.i = nnn,
            0xD => self.draw(x, y, n),
            else => return error.UnknownOpcode,
        }
    }

    fn draw(self: *Chip8, x: u4, y: u4, n: u4) void {
        const start_x = self.v[x] % width;
        const start_y = self.v[y] % height;
        self.v[0xF] = 0;

        for (0..n) |row| {
            const py = start_y + row;
            if (py >= height) break;
            const sprite = self.memory[(self.i + row) & 0xFFF];

            for (0..8) |col| {
                const px = start_x + col;
                if (px >= width) break;
                if (sprite & (@as(u8, 0x80) >> @intCast(col)) == 0) continue;

                const pixel = &self.display[py * width + px];
                if (pixel.* == 1) self.v[0xF] = 1;
                pixel.* ^= 1;
            }
        }
    }

    fn skip(self: *Chip8) void {
        self.pc = (self.pc + 2) & 0xFFF;
    }
};

fn machineWith(rom: []const u8) !Chip8 {
    var c = Chip8.init(0);
    try c.loadRom(rom, 0);
    return c;
}

test "init puts the font at 0x50 and starts at 0x200" {
    const c = Chip8.init(0);
    try std.testing.expectEqual(0xF0, c.memory[font_start]);
    try std.testing.expectEqual(0x80, c.memory[font_start + font.len - 1]);
    try std.testing.expectEqual(program_start, c.pc);
}

test "loadRom copies the ROM to 0x200" {
    var c = Chip8.init(0);
    try c.loadRom(&.{ 0x12, 0x34 }, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, c.memory[program_start..][0..2]);
}

test "loadRom resets the machine before loading" {
    var c = try machineWith(&.{ 0x6A, 0x05, 0x12, 0x34 });
    try c.step();
    c.display[0] = 1;

    try c.loadRom(&.{ 0x00, 0xE0 }, 0);
    try std.testing.expectEqual(0, c.v[0xA]);
    try std.testing.expectEqual(program_start, c.pc);
    try std.testing.expectEqual(0, c.display[0]);
    // The old ROM was longer, and its tail must not survive.
    try std.testing.expectEqual(0, c.memory[program_start + 2]);
    try std.testing.expectEqual(0xF0, c.memory[font_start]);
}

test "loadRom rejects a ROM that doesn't fit and keeps the old one" {
    var c = try machineWith(&.{ 0x12, 0x34 });
    const too_big: [memory_size - program_start + 1]u8 = @splat(0);
    try std.testing.expectError(error.RomTooLarge, c.loadRom(&too_big, 0));
    try std.testing.expectEqual(0x12, c.memory[program_start]);
}

test "6XNN sets VX" {
    var c = try machineWith(&.{ 0x6A, 0x05 });
    try c.step();
    try std.testing.expectEqual(5, c.v[0xA]);
    try std.testing.expectEqual(0x202, c.pc);
}

test "7XNN adds to VX, wraps, and leaves VF alone" {
    var c = try machineWith(&.{ 0x60, 0xFF, 0x70, 0x02 });
    try c.step();
    try c.step();
    try std.testing.expectEqual(1, c.v[0]);
    try std.testing.expectEqual(0, c.v[0xF]);
}

test "1NNN jumps" {
    var c = try machineWith(&.{ 0x12, 0x34 });
    try c.step();
    try std.testing.expectEqual(0x234, c.pc);
}

test "ANNN sets I" {
    var c = try machineWith(&.{ 0xA1, 0x23 });
    try c.step();
    try std.testing.expectEqual(0x123, c.i);
}

test "00E0 clears the screen" {
    var c = try machineWith(&.{ 0x00, 0xE0 });
    c.display[5] = 1;
    try c.step();
    try std.testing.expect(std.mem.allEqual(u8, &c.display, 0));
}

test "DXYN draws a sprite, and drawing it again erases it and sets VF" {
    // I = font "0", then draw it twice at (V0, V0) = (0, 0)
    var c = try machineWith(&.{ 0xA0, 0x50, 0xD0, 0x05, 0xD0, 0x05 });
    try c.step();
    try c.step();
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 0 }, c.display[0..5]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 1, 0 }, c.display[width..][0..5]);
    try std.testing.expectEqual(0, c.v[0xF]);

    try c.step();
    try std.testing.expect(std.mem.allEqual(u8, &c.display, 0));
    try std.testing.expectEqual(1, c.v[0xF]);
}

test "DXYN reads VF as a coordinate before resetting it" {
    // VF = 10, then draw the top row of font "0" at (VF, VF)
    var c = try machineWith(&.{ 0x6F, 10, 0xA0, 0x50, 0xDF, 0xF1 });
    for (0..3) |_| try c.step();
    try std.testing.expectEqual(1, c.display[10 * width + 10]);
    try std.testing.expectEqual(0, c.v[0xF]);
}

test "DXYN clips at the right and bottom edges" {
    // V0 = 62, so x = 62 and y = 62 % 32 = 30
    var c = try machineWith(&.{ 0x60, 62, 0xA0, 0x50, 0xD0, 0x05 });
    for (0..3) |_| try c.step();
    try std.testing.expectEqual(1, c.display[30 * width + 62]);
    try std.testing.expectEqual(1, c.display[30 * width + 63]);
    try std.testing.expectEqual(1, c.display[31 * width + 62]);
    try std.testing.expectEqual(0, c.display[30 * width + 0]);
    try std.testing.expectEqual(0, c.display[0 * width + 62]);
}

test "unknown opcodes return an error" {
    var c = try machineWith(&.{ 0x01, 0x23 });
    try std.testing.expectError(error.UnknownOpcode, c.step());
}

// The remaining 29 instructions. Each test fails until its instruction works.
// The behavior follows the COSMAC VIP, as SPEC.md describes.

fn runSteps(c: *Chip8, count: usize) !void {
    for (0..count) |_| try c.step();
}

// Skips. A skip moves pc past one more instruction, so 2 extra bytes.

test "3XNN skips when VX equals NN" {
    var equal = try machineWith(&.{ 0x60, 0x05, 0x30, 0x05 });
    try runSteps(&equal, 2);
    try std.testing.expectEqual(0x206, equal.pc);

    var different = try machineWith(&.{ 0x60, 0x05, 0x30, 0x06 });
    try runSteps(&different, 2);
    try std.testing.expectEqual(0x204, different.pc);
}

test "4XNN skips when VX differs from NN" {
    var different = try machineWith(&.{ 0x60, 0x05, 0x40, 0x06 });
    try runSteps(&different, 2);
    try std.testing.expectEqual(0x206, different.pc);

    var equal = try machineWith(&.{ 0x60, 0x05, 0x40, 0x05 });
    try runSteps(&equal, 2);
    try std.testing.expectEqual(0x204, equal.pc);
}

test "5XY0 skips when VX equals VY" {
    var equal = try machineWith(&.{ 0x60, 0x05, 0x61, 0x05, 0x50, 0x10 });
    try runSteps(&equal, 3);
    try std.testing.expectEqual(0x208, equal.pc);

    var different = try machineWith(&.{ 0x60, 0x05, 0x61, 0x06, 0x50, 0x10 });
    try runSteps(&different, 3);
    try std.testing.expectEqual(0x206, different.pc);
}

test "9XY0 skips when VX differs from VY" {
    var different = try machineWith(&.{ 0x60, 0x05, 0x61, 0x06, 0x90, 0x10 });
    try runSteps(&different, 3);
    try std.testing.expectEqual(0x208, different.pc);

    var equal = try machineWith(&.{ 0x60, 0x05, 0x61, 0x05, 0x90, 0x10 });
    try runSteps(&equal, 3);
    try std.testing.expectEqual(0x206, equal.pc);
}

// Subroutines

test "2NNN pushes the return address and jumps" {
    var c = try machineWith(&.{ 0x22, 0x06 });
    try c.step();
    try std.testing.expectEqual(0x206, c.pc);
    try std.testing.expectEqual(1, c.sp);
    try std.testing.expectEqual(0x202, c.stack[0]);
}

test "00EE returns to the instruction after the call" {
    // 0x200: call 0x204. 0x204: return.
    var c = try machineWith(&.{ 0x22, 0x04, 0x00, 0x00, 0x00, 0xEE });
    try runSteps(&c, 2);
    try std.testing.expectEqual(0x202, c.pc);
    try std.testing.expectEqual(0, c.sp);
}

test "a 17th nested call is a stack overflow" {
    // 0x200 calls itself, so every step pushes one more address.
    var c = try machineWith(&.{ 0x22, 0x00 });
    try runSteps(&c, 16);
    try std.testing.expectError(error.StackOverflow, c.step());
}

test "00EE with an empty stack is a stack underflow" {
    var c = try machineWith(&.{ 0x00, 0xEE });
    try std.testing.expectError(error.StackUnderflow, c.step());
}

// Arithmetic. Each ROM sets VF first, so a test notices when VF isn't written.

test "8XY0 copies VY into VX" {
    var c = try machineWith(&.{ 0x61, 0x07, 0x80, 0x10 });
    try runSteps(&c, 2);
    try std.testing.expectEqual(7, c.v[0]);
}

test "8XY1 ORs and resets VF" {
    var c = try machineWith(&.{ 0x6F, 0x01, 0x60, 0x0F, 0x61, 0xF0, 0x80, 0x11 });
    try runSteps(&c, 4);
    try std.testing.expectEqual(0xFF, c.v[0]);
    try std.testing.expectEqual(0, c.v[0xF]);
}

test "8XY2 ANDs and resets VF" {
    var c = try machineWith(&.{ 0x6F, 0x01, 0x60, 0x0F, 0x61, 0x3C, 0x80, 0x12 });
    try runSteps(&c, 4);
    try std.testing.expectEqual(0x0C, c.v[0]);
    try std.testing.expectEqual(0, c.v[0xF]);
}

test "8XY3 XORs and resets VF" {
    var c = try machineWith(&.{ 0x6F, 0x01, 0x60, 0x0F, 0x61, 0x3C, 0x80, 0x13 });
    try runSteps(&c, 4);
    try std.testing.expectEqual(0x33, c.v[0]);
    try std.testing.expectEqual(0, c.v[0xF]);
}

test "8XY4 adds and sets VF to the carry" {
    var carry = try machineWith(&.{ 0x6F, 0x00, 0x60, 0xFF, 0x61, 0x02, 0x80, 0x14 });
    try runSteps(&carry, 4);
    try std.testing.expectEqual(0x01, carry.v[0]);
    try std.testing.expectEqual(1, carry.v[0xF]);

    var no_carry = try machineWith(&.{ 0x6F, 0x01, 0x60, 0x01, 0x61, 0x02, 0x80, 0x14 });
    try runSteps(&no_carry, 4);
    try std.testing.expectEqual(0x03, no_carry.v[0]);
    try std.testing.expectEqual(0, no_carry.v[0xF]);
}

test "8XY5 subtracts VY from VX and sets VF to 1 when there's no borrow" {
    var no_borrow = try machineWith(&.{ 0x6F, 0x00, 0x60, 0x05, 0x61, 0x03, 0x80, 0x15 });
    try runSteps(&no_borrow, 4);
    try std.testing.expectEqual(0x02, no_borrow.v[0]);
    try std.testing.expectEqual(1, no_borrow.v[0xF]);

    var borrow = try machineWith(&.{ 0x6F, 0x01, 0x60, 0x03, 0x61, 0x05, 0x80, 0x15 });
    try runSteps(&borrow, 4);
    try std.testing.expectEqual(0xFE, borrow.v[0]);
    try std.testing.expectEqual(0, borrow.v[0xF]);

    // Equal values don't borrow, so VF is 1 here too.
    var equal = try machineWith(&.{ 0x6F, 0x00, 0x60, 0x05, 0x61, 0x05, 0x80, 0x15 });
    try runSteps(&equal, 4);
    try std.testing.expectEqual(0x00, equal.v[0]);
    try std.testing.expectEqual(1, equal.v[0xF]);
}

test "8XY6 shifts VY right into VX and sets VF to the bit shifted out" {
    var c = try machineWith(&.{ 0x6F, 0x00, 0x60, 0x00, 0x61, 0x05, 0x80, 0x16 });
    try runSteps(&c, 4);
    try std.testing.expectEqual(0x02, c.v[0]);
    try std.testing.expectEqual(1, c.v[0xF]);
    try std.testing.expectEqual(0x05, c.v[1]);
}

test "8XY7 subtracts VX from VY and sets VF to 1 when there's no borrow" {
    var no_borrow = try machineWith(&.{ 0x6F, 0x00, 0x60, 0x03, 0x61, 0x05, 0x80, 0x17 });
    try runSteps(&no_borrow, 4);
    try std.testing.expectEqual(0x02, no_borrow.v[0]);
    try std.testing.expectEqual(1, no_borrow.v[0xF]);

    var borrow = try machineWith(&.{ 0x6F, 0x01, 0x60, 0x05, 0x61, 0x03, 0x80, 0x17 });
    try runSteps(&borrow, 4);
    try std.testing.expectEqual(0xFE, borrow.v[0]);
    try std.testing.expectEqual(0, borrow.v[0xF]);
}

test "8XYE shifts VY left into VX and sets VF to the bit shifted out" {
    var c = try machineWith(&.{ 0x6F, 0x00, 0x60, 0x00, 0x61, 0x81, 0x80, 0x1E });
    try runSteps(&c, 4);
    try std.testing.expectEqual(0x02, c.v[0]);
    try std.testing.expectEqual(1, c.v[0xF]);
    try std.testing.expectEqual(0x81, c.v[1]);
}

test "when X is F, the flag overwrites the result" {
    // VF = 0xFF + 3 would be 0x02, but the carry is written last.
    var add = try machineWith(&.{ 0x6F, 0xFF, 0x61, 0x03, 0x8F, 0x14 });
    try runSteps(&add, 3);
    try std.testing.expectEqual(1, add.v[0xF]);

    // VF = 5 - 3 would be 0x02, but "no borrow" is written last.
    var sub = try machineWith(&.{ 0x6F, 0x05, 0x61, 0x03, 0x8F, 0x15 });
    try runSteps(&sub, 3);
    try std.testing.expectEqual(1, sub.v[0xF]);

    // VF = 4 >> 1 would be 0x02, but the shifted-out bit is 0.
    var shift = try machineWith(&.{ 0x61, 0x04, 0x8F, 0x16 });
    try runSteps(&shift, 2);
    try std.testing.expectEqual(0, shift.v[0xF]);
}

// Memory

test "BNNN jumps to NNN plus V0" {
    var c = try machineWith(&.{ 0x60, 0x04, 0xB3, 0x00 });
    try runSteps(&c, 2);
    try std.testing.expectEqual(0x304, c.pc);
}

test "FX1E adds VX to I" {
    var c = try machineWith(&.{ 0xA1, 0x00, 0x60, 0x05, 0xF0, 0x1E });
    try runSteps(&c, 3);
    try std.testing.expectEqual(0x105, c.i);
}

test "FX29 points I at the font character for VX" {
    var c = try machineWith(&.{ 0x60, 0x0A, 0xF0, 0x29 });
    try runSteps(&c, 2);
    try std.testing.expectEqual(font_start + 0xA * 5, c.i);
}

test "FX33 stores the decimal digits of VX at I" {
    var c = try machineWith(&.{ 0x60, 234, 0xA3, 0x00, 0xF0, 0x33 });
    try runSteps(&c, 3);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4 }, c.memory[0x300..][0..3]);
}

test "FX55 stores V0 through VX at I and moves I past them" {
    var c = try machineWith(&.{ 0x60, 1, 0x61, 2, 0x62, 3, 0x63, 4, 0xA3, 0x00, 0xF2, 0x55 });
    try runSteps(&c, 6);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0 }, c.memory[0x300..][0..4]);
    try std.testing.expectEqual(0x303, c.i);
}

test "FX65 loads V0 through VX from I and moves I past them" {
    var c = try machineWith(&.{ 0xA3, 0x00, 0xF2, 0x65 });
    @memcpy(c.memory[0x300..][0..4], &[_]u8{ 7, 8, 9, 10 });
    try runSteps(&c, 2);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8, 9, 0 }, c.v[0..4]);
    try std.testing.expectEqual(0x303, c.i);
}

// Timers and random

test "FX15 sets the delay timer" {
    var c = try machineWith(&.{ 0x60, 60, 0xF0, 0x15 });
    try runSteps(&c, 2);
    try std.testing.expectEqual(60, c.delay_timer);
}

test "FX18 sets the sound timer" {
    var c = try machineWith(&.{ 0x60, 60, 0xF0, 0x18 });
    try runSteps(&c, 2);
    try std.testing.expectEqual(60, c.sound_timer);
}

test "FX07 reads the delay timer into VX" {
    var c = try machineWith(&.{ 0xF0, 0x07 });
    c.delay_timer = 42;
    try c.step();
    try std.testing.expectEqual(42, c.v[0]);
}

test "tickTimers counts both timers down and stops at 0" {
    var c = Chip8.init(0);
    c.delay_timer = 2;
    c.sound_timer = 1;
    c.tickTimers();
    try std.testing.expectEqual(1, c.delay_timer);
    try std.testing.expectEqual(0, c.sound_timer);
    c.tickTimers();
    try std.testing.expectEqual(0, c.delay_timer);
    try std.testing.expectEqual(0, c.sound_timer);
}

test "CXNN masks a random byte with NN" {
    for (0..32) |seed| {
        var c = Chip8.init(0);
        try c.loadRom(&.{ 0xC0, 0x0F }, seed);
        try c.step();
        try std.testing.expectEqual(0, c.v[0] & 0xF0);
    }
}

test "CXNN gives the same numbers for the same seed" {
    var a = Chip8.init(0);
    var b = Chip8.init(0);
    try a.loadRom(&.{ 0xC0, 0xFF }, 7);
    try b.loadRom(&.{ 0xC0, 0xFF }, 7);
    try a.step();
    try b.step();
    try std.testing.expectEqual(a.v[0], b.v[0]);
}

// Input

test "EX9E skips when the key in VX is pressed" {
    var pressed = try machineWith(&.{ 0x60, 0x05, 0xE0, 0x9E });
    pressed.keys[5] = true;
    try runSteps(&pressed, 2);
    try std.testing.expectEqual(0x206, pressed.pc);

    var released = try machineWith(&.{ 0x60, 0x05, 0xE0, 0x9E });
    try runSteps(&released, 2);
    try std.testing.expectEqual(0x204, released.pc);
}

test "EXA1 skips when the key in VX is not pressed" {
    var released = try machineWith(&.{ 0x60, 0x05, 0xE0, 0xA1 });
    try runSteps(&released, 2);
    try std.testing.expectEqual(0x206, released.pc);

    var pressed = try machineWith(&.{ 0x60, 0x05, 0xE0, 0xA1 });
    pressed.keys[5] = true;
    try runSteps(&pressed, 2);
    try std.testing.expectEqual(0x204, pressed.pc);
}

test "FX0A waits until a key is pressed and released, then stores it in VX" {
    var c = try machineWith(&.{ 0xF0, 0x0A });

    try c.step();
    try std.testing.expectEqual(0x200, c.pc);

    c.keys[7] = true;
    try c.step();
    try std.testing.expectEqual(0x200, c.pc);

    c.keys[7] = false;
    try c.step();
    try std.testing.expectEqual(7, c.v[0]);
    try std.testing.expectEqual(0x202, c.pc);
}
