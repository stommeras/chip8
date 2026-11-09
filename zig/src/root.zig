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
            0x6 => self.v[x] = nn,
            0x7 => self.v[x] +%= nn,
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
