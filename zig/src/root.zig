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

/// Behaviors that differ between CHIP-8 machines (SPEC.md). The bit order is the order of the fields.
pub const Quirks = packed struct(u8) {
    vf_reset: bool = true,
    shift_uses_vy: bool = true,
    increment_i: bool = true,
    jump_uses_v0: bool = true,
    display_wait: bool = true,
    _: u3 = 0,

    pub const vip: Quirks = .{};
    pub const schip: Quirks = .{
        .vf_reset = false,
        .shift_uses_vy = false,
        .increment_i = false,
        .jump_uses_v0 = false,
        .display_wait = false,
    };
};

pub const Chip8 = struct {
    memory: [memory_size]u8 = @splat(0),
    v: [16]u8 = @splat(0),
    // Addresses are u12, so they can't point past memory, and +% wraps them at 0xFFF.
    i: u12 = 0,
    pc: u12 = program_start,
    stack: [16]u12 = @splat(0),
    sp: u8 = 0,
    delay_timer: u8 = 0,
    sound_timer: u8 = 0,
    display: [width * height]u8 = @splat(0),
    keys: [16]bool = @splat(false),
    rng: std.Random.Xoshiro256,
    /// Survives `loadRom`.
    quirks: Quirks = .vip,
    /// While FX0A waits, the key that went down. FX0A finishes when it comes back up.
    held_key: ?u4 = null,

    pub fn init(seed: u64) Chip8 {
        var c: Chip8 = .{ .rng = .init(seed) };
        @memcpy(c.memory[font_start..][0..font.len], &font);
        return c;
    }

    /// Resets the machine, except for its quirks, and copies `rom` to 0x200. On error the machine is left as it was.
    /// `rom` must not point into the machine's own memory, since the reset clears it first.
    pub fn loadRom(self: *Chip8, rom: []const u8, seed: u64) error{RomTooLarge}!void {
        if (rom.len > memory_size - program_start) return error.RomTooLarge;
        const quirks = self.quirks;
        self.* = .init(seed);
        self.quirks = quirks;
        @memcpy(self.memory[program_start..][0..rom.len], rom);
    }

    /// Counts the delay and sound timers down by one, stopping at 0. The host calls it 60 times a second.
    pub fn tickTimers(self: *Chip8) void {
        self.delay_timer -|= 1;
        self.sound_timer -|= 1;
    }

    pub fn step(self: *Chip8) error{ UnknownOpcode, StackOverflow, StackUnderflow }!void {
        // Fetch
        const hi = self.memory[self.pc];
        const lo = self.memory[self.pc +% 1];
        const opcode = (@as(u16, hi) << 8) | lo;
        self.pc +%= 2;

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
                0x00EE => {
                    if (self.sp == 0) return error.StackUnderflow;
                    self.sp -= 1;
                    self.pc = self.stack[self.sp];
                },
                else => return error.UnknownOpcode,
            },
            0x1 => self.pc = nnn,
            0x2 => {
                if (self.sp == self.stack.len) return error.StackOverflow;
                self.stack[self.sp] = self.pc;
                self.sp += 1;
                self.pc = nnn;
            },
            0x3 => if (self.v[x] == nn) self.skip(),
            0x4 => if (self.v[x] != nn) self.skip(),
            0x5 => if (self.v[x] == self.v[y]) self.skip(),
            0x6 => self.v[x] = nn,
            0x7 => self.v[x] +%= nn,
            0x8 => switch (n) {
                0x0 => self.v[x] = self.v[y],
                0x1 => {
                    self.v[x] |= self.v[y];
                    if (self.quirks.vf_reset) self.v[0xF] = 0;
                },
                0x2 => {
                    self.v[x] &= self.v[y];
                    if (self.quirks.vf_reset) self.v[0xF] = 0;
                },
                0x3 => {
                    self.v[x] ^= self.v[y];
                    if (self.quirks.vf_reset) self.v[0xF] = 0;
                },
                0x4 => {
                    const sum, const carry = @addWithOverflow(self.v[x], self.v[y]);
                    self.v[x] = sum;
                    self.v[0xF] = carry;
                },
                0x5 => {
                    const difference, const borrow = @subWithOverflow(self.v[x], self.v[y]);
                    self.v[x] = difference;
                    self.v[0xF] = 1 - borrow;
                },
                0x6 => {
                    const source = self.shiftSource(x, y);
                    const shifted_out = source & 1;
                    self.v[x] = source >> 1;
                    self.v[0xF] = shifted_out;
                },
                0x7 => {
                    const difference, const borrow = @subWithOverflow(self.v[y], self.v[x]);
                    self.v[x] = difference;
                    self.v[0xF] = 1 - borrow;
                },
                0xE => {
                    const shifted, const shifted_out = @shlWithOverflow(self.shiftSource(x, y), 1);
                    self.v[x] = shifted;
                    self.v[0xF] = shifted_out;
                },
                else => return error.UnknownOpcode,
            },
            0x9 => if (self.v[x] != self.v[y]) self.skip(),
            0xA => self.i = nnn,
            0xB => self.pc = nnn +% self.v[if (self.quirks.jump_uses_v0) 0 else x],
            0xC => self.v[x] = self.rng.random().int(u8) & nn,
            0xD => self.draw(x, y, n),
            0xE => {
                // Only the low 4 bits of VX name a key.
                const pressed = self.keys[@as(u4, @truncate(self.v[x]))];
                switch (nn) {
                    0x9E => if (pressed) self.skip(),
                    0xA1 => if (!pressed) self.skip(),
                    else => return error.UnknownOpcode,
                }
            },
            0xF => switch (nn) {
                0x07 => self.v[x] = self.delay_timer,
                0x0A => self.waitForKey(x),
                0x15 => self.delay_timer = self.v[x],
                0x18 => self.sound_timer = self.v[x],
                0x1E => self.i +%= self.v[x],
                0x29 => self.i = font_start + @as(u12, self.v[x] & 0xF) * 5,
                0x33 => {
                    const value = self.v[x];
                    self.memory[self.i] = value / 100;
                    self.memory[self.i +% 1] = value / 10 % 10;
                    self.memory[self.i +% 2] = value % 10;
                },
                0x55 => {
                    for (self.v[0 .. @as(usize, x) + 1], 0..) |register, offset| {
                        self.memory[self.i +% @as(u12, @intCast(offset))] = register;
                    }
                    self.advanceI(x);
                },
                0x65 => {
                    for (self.v[0 .. @as(usize, x) + 1], 0..) |*register, offset| {
                        register.* = self.memory[self.i +% @as(u12, @intCast(offset))];
                    }
                    self.advanceI(x);
                },
                else => return error.UnknownOpcode,
            },
        }
    }

    fn shiftSource(self: *const Chip8, x: u4, y: u4) u8 {
        return self.v[if (self.quirks.shift_uses_vy) y else x];
    }

    fn advanceI(self: *Chip8, x: u4) void {
        if (self.quirks.increment_i) self.i +%= @as(u12, x) + 1;
    }

    /// FX0A: waits for a key to go down and come back up, then stores it in VX.
    /// Waiting means moving pc back, so the same instruction runs again next step.
    fn waitForKey(self: *Chip8, x: u4) void {
        if (self.held_key) |key| {
            if (!self.keys[key]) {
                self.v[x] = key;
                self.held_key = null;
                return;
            }
        } else if (std.mem.findScalar(bool, &self.keys, true)) |key| {
            self.held_key = @intCast(key);
        }
        self.pc -%= 2;
    }

    fn draw(self: *Chip8, x: u4, y: u4, n: u4) void {
        const start_x = self.v[x] % width;
        const start_y = self.v[y] % height;
        self.v[0xF] = 0;

        for (0..n) |row| {
            const py = start_y + row;
            if (py >= height) break;
            const sprite = self.memory[self.i +% @as(u12, @intCast(row))];

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
        self.pc +%= 2;
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

// The other instructions. The behavior follows the COSMAC VIP, as SPEC.md describes.

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

test "8XY6 and 8XYE still set VF right when X and Y are the same register" {
    // V1 = 5, then 8116: V1 = 5 >> 1 = 2, and the bit shifted out is 1
    var right = try machineWith(&.{ 0x61, 0x05, 0x81, 0x16 });
    try runSteps(&right, 2);
    try std.testing.expectEqual(0x02, right.v[1]);
    try std.testing.expectEqual(1, right.v[0xF]);

    // V1 = 0x81, then 811E: V1 = 0x02, and the bit shifted out is 1
    var left = try machineWith(&.{ 0x61, 0x81, 0x81, 0x1E });
    try runSteps(&left, 2);
    try std.testing.expectEqual(0x02, left.v[1]);
    try std.testing.expectEqual(1, left.v[0xF]);
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

    // VF = 5 - 3 (V1 - VF) would be 0x02, but "no borrow" is written last.
    var reverse_sub = try machineWith(&.{ 0x6F, 0x03, 0x61, 0x05, 0x8F, 0x17 });
    try runSteps(&reverse_sub, 3);
    try std.testing.expectEqual(1, reverse_sub.v[0xF]);
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

// Quirks

test "with vf_reset off, 8XY1, 8XY2 and 8XY3 leave VF alone" {
    var c = try machineWith(&.{ 0x6F, 0x01, 0x60, 0x0F, 0x61, 0xF0, 0x80, 0x11, 0x80, 0x12, 0x80, 0x13 });
    c.quirks.vf_reset = false;
    try runSteps(&c, 6);
    try std.testing.expectEqual(1, c.v[0xF]);
}

test "with shift_uses_vy off, 8XY6 and 8XYE shift VX in place" {
    var right = try machineWith(&.{ 0x60, 0x03, 0x61, 0x08, 0x80, 0x16 });
    right.quirks.shift_uses_vy = false;
    try runSteps(&right, 3);
    try std.testing.expectEqual(0x01, right.v[0]);
    try std.testing.expectEqual(1, right.v[0xF]);
    try std.testing.expectEqual(0x08, right.v[1]);

    var left = try machineWith(&.{ 0x60, 0x81, 0x61, 0x08, 0x80, 0x1E });
    left.quirks.shift_uses_vy = false;
    try runSteps(&left, 3);
    try std.testing.expectEqual(0x02, left.v[0]);
    try std.testing.expectEqual(1, left.v[0xF]);
    try std.testing.expectEqual(0x08, left.v[1]);
}

test "with jump_uses_v0 off, BXNN jumps to XNN plus VX" {
    var c = try machineWith(&.{ 0x63, 0x08, 0xB3, 0x00 });
    c.quirks.jump_uses_v0 = false;
    try runSteps(&c, 2);
    try std.testing.expectEqual(0x308, c.pc);
}

test "with increment_i off, FX55 and FX65 leave I alone" {
    var store = try machineWith(&.{ 0x60, 1, 0x61, 2, 0xA3, 0x00, 0xF1, 0x55 });
    store.quirks.increment_i = false;
    try runSteps(&store, 4);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, store.memory[0x300..][0..2]);
    try std.testing.expectEqual(0x300, store.i);

    var load = try machineWith(&.{ 0xA3, 0x00, 0xF1, 0x65 });
    load.quirks.increment_i = false;
    @memcpy(load.memory[0x300..][0..2], &[_]u8{ 7, 8 });
    try runSteps(&load, 2);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, load.v[0..2]);
    try std.testing.expectEqual(0x300, load.i);
}

test "loadRom keeps the quirks" {
    var c = Chip8.init(0);
    c.quirks = .schip;
    try c.loadRom(&.{}, 0);
    try std.testing.expectEqual(Quirks.schip, c.quirks);
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

test "CXNN takes the low byte of each Xoshiro256 output" {
    var c = try machineWith(&.{ 0xC0, 0xFF, 0xC1, 0xFF });
    try runSteps(&c, 2);
    const seed_0_outputs = [2]u64{ 0x53175d61490b23df, 0x61da6f3dc380d507 };
    try std.testing.expectEqualSlices(u8, &.{ @truncate(seed_0_outputs[0]), @truncate(seed_0_outputs[1]) }, c.v[0..2]);
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

test "addresses wrap from 0xFFF to 0x000" {
    // V0..V2 = 1, 2, 3, I = 0xFFE, then FX55 stores across the end of memory.
    var c = try machineWith(&.{ 0x60, 1, 0x61, 2, 0x62, 3, 0xAF, 0xFE, 0xF2, 0x55 });
    try runSteps(&c, 5);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, c.memory[0xFFE..]);
    try std.testing.expectEqual(3, c.memory[0x000]);
    try std.testing.expectEqual(0x001, c.i);

    // An instruction at 0xFFF has its second byte at 0x000.
    c.pc = 0xFFF;
    c.memory[0xFFF] = 0x6B;
    c.memory[0x000] = 0x07;
    try c.step();
    try std.testing.expectEqual(7, c.v[0xB]);
    try std.testing.expectEqual(0x001, c.pc);
}
