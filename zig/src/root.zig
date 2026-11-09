//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

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

    pub fn loadRom(self: *Chip8, rom: []const u8) error{RomTooLarge}!void {
        if (rom.len > memory_size - program_start) return error.RomTooLarge;
        @memcpy(self.memory[program_start..][0..rom.len], rom);
    }
};

test "init puts the font at 0x50 and starts at 0x200" {
    const c = Chip8.init(0);
    try std.testing.expectEqual(0xF0, c.memory[font_start]);
    try std.testing.expectEqual(0x80, c.memory[font_start + font.len - 1]);
    try std.testing.expectEqual(program_start, c.pc);
}

test "loadRom copies the ROM to 0x200" {
    var c = Chip8.init(0);
    try c.loadRom(&.{ 0x12, 0x34 });
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, c.memory[program_start..][0..2]);
}

test "loadRom rejects a ROM that doesn't fit" {
    var c = Chip8.init(0);
    const too_big: [memory_size - program_start + 1]u8 = @splat(0);
    try std.testing.expectError(error.RomTooLarge, c.loadRom(&too_big));
}
