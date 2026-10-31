//! Remove screen's title sequences from tmux pane output across arbitrary chunks.
const std = @import("std");
const Filter = @This();

/// Only an ESC retained from the previous chunk can add an output byte.
pub const max_expansion = 1;

state: enum { ground, escape, string, string_escape } = .ground,

/// Bytes of the current title dropped so far.
len: usize = 0,

/// After this many bytes the title is over even without its end, so
/// that an `ESC k` that is never terminated can't drop all of a
/// pane's later output.
const max_len = 1024;

pub fn filter(
    self: *Filter,
    data: []const u8,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    for (data) |byte| switch (self.state) {
        .ground => if (byte == 0x1b) {
            self.state = .escape;
        } else {
            try writer.writeByte(byte);
        },

        .escape => switch (byte) {
            'k' => {
                self.state = .string;
                self.len = 0;
            },

            // ESC ESC: the first one still isn't ours.
            0x1b => try writer.writeByte(0x1b),

            else => {
                self.state = .ground;
                try writer.writeByte(0x1b);
                try writer.writeByte(byte);
            },
        },

        // BEL terminates too: it's what the OSC form of this uses and
        // some shells reuse the same title string for both.
        .string, .string_escape => {
            self.state = switch (byte) {
                0x07 => .ground,
                0x1b => .string_escape,
                '\\' => if (self.state == .string_escape) .ground else .string,
                else => .string,
            };
            self.len += 1;
            if (self.len >= max_len) self.state = .ground;
        },
    };
}
test "tmux title filter" {
    const testing = std.testing;

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var f: Filter = .{};

    // Ended by ST or BEL, also when split across chunks, and anything else
    // after ESC passes through.
    try f.filter("a\x1bkone\x1b\\b\x1bktwo\x07c\x1b\x1bkthr", &writer);
    try f.filter("ee\x1b\\d\x1b[1m", &writer);
    try testing.expectEqualStrings("abc\x1bd\x1b[1m", writer.buffered());

    // A title that never ends stops being one after max_len bytes.
    writer = .fixed(&buf);
    try f.filter("\x1bk", &writer);
    for (0..Filter.max_len + 3) |_| try f.filter("x", &writer);
    try f.filter("tail", &writer);
    try testing.expectEqualStrings("xxxtail", writer.buffered());
}

test "tmux title filter needs at most one byte beyond its input" {
    for ([_][]const u8{ "", "\x1b", "\x1bk", "\x1bkname\x1b" }) |prefix| {
        for (0..256) |value| {
            var title: Filter = .{};
            var prefix_buffer: [32]u8 = undefined;
            var prefix_writer: std.Io.Writer = .fixed(&prefix_buffer);
            try title.filter(prefix, &prefix_writer);
            var buffer: [2]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try title.filter(&.{@intCast(value)}, &writer);
        }
    }
}

test "tmux status protocols survive control decoding and title filtering" {
    const terminal = @import("../terminal/main.zig");
    const Handler = struct {
        query: bool = false,
        status: bool = false,
        unexpected: bool = false,

        pub fn deinit(_: *@This()) void {}

        pub fn vt(self: *@This(), comptime action: terminal.StreamAction.Tag, value: anytype) void {
            switch (action) {
                .program_status => self.query = value == .query,
                .osc_unknown => self.status = std.mem.eql(u8, value.content, "21337;status=working"),
                else => self.unexpected = true,
            }
        }
    };
    var encoded = "\\033]7501;?\\033\\134\\033]21337;status=working\\007".*;
    const decoded = terminal.tmux.unescape(&encoded);
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var title: Filter = .{};
    try title.filter(decoded, &writer);
    var stream: terminal.Stream(Handler) = .init(.{
        .handler = .{},
        .allocator = std.testing.allocator,
        .osc_unknown_max_bytes = 4096,
    });
    defer stream.deinit();
    stream.nextSlice(writer.buffered());
    try std.testing.expect(stream.handler.query);
    try std.testing.expect(stream.handler.status);
    try std.testing.expect(!stream.handler.unexpected);
}
