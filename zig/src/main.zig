//! Runs a ROM for a fixed number of instructions and prints the screen to the terminal.
const std = @import("std");
const Io = std.Io;

const chip8 = @import("chip8");

const steps = 1000;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: chip8 <rom.ch8>\n", .{});
        std.process.exit(1);
    }

    // One byte more than fits, so loadRom can tell when a ROM is too big.
    var rom_buffer: [chip8.memory_size - chip8.program_start + 1]u8 = undefined;
    const rom = try Io.Dir.cwd().readFile(io, args[1], &rom_buffer);

    var machine = chip8.Chip8.init(0);
    try machine.loadRom(rom, 0);
    for (0..steps) |_| try machine.step();

    var out_buffer: [4096]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    const out = &out_file.interface;

    // Two characters per pixel, since terminal characters are about twice as tall as they are wide.
    for (0..chip8.height) |row| {
        for (machine.display[row * chip8.width ..][0..chip8.width]) |pixel| {
            try out.writeAll(if (pixel == 1) "##" else "  ");
        }
        try out.writeByte('\n');
    }
    try out.flush();
}
