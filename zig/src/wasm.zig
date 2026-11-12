const std = @import("std");

const chip8 = @import("chip8");

const rom_capacity = chip8.memory_size - chip8.program_start;

var machine: chip8.Chip8 = .init(0);
var rom_buffer: [rom_capacity]u8 = @splat(0);
var stopped = false;

fn offset(ptr: anytype) u32 {
    return @intCast(@intFromPtr(ptr));
}

export fn rom_ptr() u32 {
    return offset(&rom_buffer);
}

export fn load_rom(len: u32, seed: u32, quirks: u32) u32 {
    if (len > rom_capacity) return 1;
    machine.quirks = @bitCast(@as(u8, @as(u5, @truncate(quirks))));
    machine.loadRom(rom_buffer[0..len], seed) catch unreachable;
    stopped = false;
    return 0;
}

export fn step(n: u32) void {
    for (0..n) |_| {
        if (stopped) return;
        const draws = machine.memory[machine.pc] >> 4 == 0xD;
        machine.step() catch {
            stopped = true;
            return;
        };
        if (draws and machine.quirks.display_wait) return;
    }
}

export fn tick_timers() void {
    machine.tickTimers();
}

export fn key_down(k: u32) void {
    if (k < machine.keys.len) machine.keys[k] = true;
}

export fn key_up(k: u32) void {
    if (k < machine.keys.len) machine.keys[k] = false;
}

export fn framebuffer_ptr() u32 {
    return offset(&machine.display);
}

export fn sound_on() u32 {
    return @intFromBool(machine.sound_timer > 0);
}

export fn is_stopped() u32 {
    return @intFromBool(stopped);
}

const vip_bits: u32 = @as(u8, @bitCast(chip8.Quirks.vip));
const schip_bits: u32 = @as(u8, @bitCast(chip8.Quirks.schip));

fn load(rom: []const u8) !void {
    @memcpy(rom_buffer[0..rom.len], rom);
    try std.testing.expectEqual(0, load_rom(@intCast(rom.len), 0, vip_bits));
}

test "load_rom rejects a ROM that is too long and accepts one that just fits" {
    try std.testing.expectEqual(1, load_rom(rom_capacity + 1, 0, vip_bits));
    try std.testing.expectEqual(0, load_rom(rom_capacity, 0, vip_bits));
}

test "step runs exactly n instructions" {
    try load(&.{ 0x61, 0x01, 0x62, 0x02, 0x63, 0x03 });
    step(2);
    try std.testing.expectEqual(chip8.program_start + 4, machine.pc);
    try std.testing.expectEqual(0, machine.v[3]);
}

test "step returns right after DXYN" {
    try load(&.{ 0xA0, 0x50, 0xD0, 0x05, 0x61, 0x01 });
    step(10);
    try std.testing.expectEqual(chip8.program_start + 4, machine.pc);
    try std.testing.expectEqual(0, machine.v[1]);
    step(10);
    try std.testing.expectEqual(1, machine.v[1]);
}

test "step runs on after DXYN when display_wait is off" {
    try load(&.{ 0xA0, 0x50, 0xD0, 0x05, 0x61, 0x01 });
    try std.testing.expectEqual(0, load_rom(6, 0, schip_bits));
    step(10);
    try std.testing.expectEqual(1, machine.v[1]);
}

test "a rejected load_rom leaves the quirks alone" {
    try std.testing.expectEqual(0, load_rom(0, 0, vip_bits));
    try std.testing.expectEqual(1, load_rom(rom_capacity + 1, 0, schip_bits));
    try std.testing.expectEqual(chip8.Quirks.vip, machine.quirks);
}

test "load_rom sets the quirks from the low five bits" {
    try std.testing.expectEqual(0, load_rom(0, 0, schip_bits | 0xE0));
    try std.testing.expectEqual(chip8.Quirks.schip, machine.quirks);
    try std.testing.expectEqual(0, load_rom(0, 0, vip_bits));
    try std.testing.expectEqual(chip8.Quirks.vip, machine.quirks);
}

test "an error stops the machine until the next load_rom" {
    try load(&.{ 0x01, 0x23 });
    try std.testing.expectEqual(0, is_stopped());
    step(1);
    try std.testing.expectEqual(1, is_stopped());
    const pc = machine.pc;
    step(1);
    try std.testing.expectEqual(pc, machine.pc);

    try load(&.{ 0x61, 0x01 });
    try std.testing.expectEqual(0, is_stopped());
    step(1);
    try std.testing.expectEqual(1, machine.v[1]);
}

test "keys outside 0x0 to 0xF are ignored" {
    key_down(5);
    try std.testing.expect(machine.keys[5]);
    key_up(5);
    try std.testing.expect(!machine.keys[5]);
    key_down(16);
    key_up(0xFFFF_FFFF);
}

test "sound_on follows the sound timer" {
    try load(&.{});
    try std.testing.expectEqual(0, sound_on());
    machine.sound_timer = 2;
    try std.testing.expectEqual(1, sound_on());
    tick_timers();
    tick_timers();
    try std.testing.expectEqual(0, sound_on());
}
