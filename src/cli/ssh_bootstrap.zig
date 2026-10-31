const Bootstrap = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

arena: std.heap.ArenaAllocator,
argv: []const []const u8,

pub fn init(
    alloc: Allocator,
    executable: []const u8,
    user_args: []const []const u8,
    script: []const u8,
) !?Bootstrap {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const argv = try arguments(arena.allocator(), executable, user_args, script) orelse {
        arena.deinit();
        return null;
    };
    return .{ .arena = arena, .argv = argv };
}

pub fn deinit(self: *Bootstrap) void {
    self.arena.deinit();
}

fn arguments(alloc: Allocator, executable: []const u8, user_args: []const []const u8, script: []const u8) !?[]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    try result.append(alloc, try alloc.dupe(u8, executable));
    try result.appendSlice(alloc, &.{ "-T", "-a", "-x" });
    for ([_][]const u8{
        "ControlMaster=no",
        "ControlPersist=no",
        "ClearAllForwardings=yes",
        "ForkAfterAuthentication=no",
        "StdinNull=no",
        "SessionType=default",
        "RemoteCommand=none",
    }) |setting| try result.appendSlice(alloc, &.{ "-o", setting });

    var destination: ?[]const u8 = null;
    var tokens: Arguments = .{ .args = user_args };
    while (try tokens.next()) |token| switch (token) {
        .positional => |word| {
            if (destination != null) break;
            destination = word;
        },
        .flag => |flag| switch (flag) {
            'G', 'N', 'V', 'Z' => return null,
            'n', 'f', 's', 't', 'T', 'M', 'A', 'a', 'X', 'x', 'Y' => {},
            else => try result.append(alloc, try alloc.print("-{c}", .{flag})),
        },
        .option => |option| {
            if (std.mem.indexOfScalar(u8, "OQW", option.flag) != null) return null;
            try result.append(alloc, try alloc.print("-{c}", .{option.flag}));
            try result.append(alloc, try alloc.dupe(u8, option.value));
        },
    };
    const host = destination orelse return null;
    try result.appendSlice(alloc, &.{ "--", try alloc.dupe(u8, host), try alloc.dupe(u8, script) });
    return try result.toOwnedSlice(alloc);
}

const Arguments = struct {
    args: []const []const u8,
    index: usize = 0,
    short_options: []const u8 = "",
    parse_options: bool = true,

    const Token = union(enum) {
        flag: u8,
        option: struct { flag: u8, value: []const u8 },
        positional: []const u8,
    };

    // OpenSSH's getopt specification, including options accepted after the host.
    // https://github.com/openssh/openssh-portable/blob/master/ssh.c
    fn next(self: *Arguments) error{InvalidSshArguments}!?Token {
        while (self.short_options.len == 0) {
            if (self.index == self.args.len) return null;
            const arg = self.args[self.index];
            self.index += 1;
            if (self.parse_options and std.mem.eql(u8, arg, "--")) {
                self.parse_options = false;
                continue;
            }
            if (!self.parse_options or arg.len < 2 or arg[0] != '-') return .{ .positional = arg };
            self.short_options = arg[1..];
        }

        const flag = self.short_options[0];
        self.short_options = self.short_options[1..];
        if (std.mem.indexOfScalar(u8, "BDEFIJLOPQRSWbceilmopw", flag) != null) {
            const value = if (self.short_options.len > 0) attached: {
                const value = self.short_options;
                self.short_options = "";
                break :attached value;
            } else separate: {
                if (self.index == self.args.len) return error.InvalidSshArguments;
                const value = self.args[self.index];
                self.index += 1;
                break :separate value;
            };
            return .{ .option = .{ .flag = flag, .value = value } };
        }
        if (std.mem.indexOfScalar(u8, "1246ACGKMNTVXYZafgknqstvxy", flag) == null) return error.InvalidSshArguments;
        return .{ .flag = flag };
    }
};

test "SSH bootstrap replaces the remote command and preserves connection options" {
    var command = (try Bootstrap.init(std.testing.allocator, "ssh", &.{
        "-vntt", "-i", "identity file", "server", "-p2222", "tmux", "-CC", "attach",
    }, "tic -x -")).?;
    defer command.deinit();
    const argv = command.argv;
    const tail = [_][]const u8{ "-v", "-i", "identity file", "-p", "2222", "--", "server", "tic -x -" };
    for (tail, argv[argv.len - tail.len ..]) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
    for (argv) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "tmux"));
        try std.testing.expect(!std.mem.eql(u8, arg, "-t"));
        try std.testing.expect(!std.mem.eql(u8, arg, "-n"));
    }
}

test "SSH bootstrap respects the end of options" {
    var command = (try Bootstrap.init(std.testing.allocator, "ssh", &.{ "--", "server", "-p", "9999" }, "install")).?;
    defer command.deinit();
    try std.testing.expectEqualStrings("server", command.argv[command.argv.len - 2]);
    for (command.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "9999"));
}

test "SSH bootstrap does not connect for non-session operations" {
    for ([_][]const []const u8{
        &.{ "-G", "server" },
        &.{ "-N", "server" },
        &.{ "-O", "check", "server" },
        &.{ "-Q", "cipher" },
        &.{ "-W", "target:22", "server" },
        &.{"-V"},
    }) |args| try std.testing.expect(try Bootstrap.init(std.testing.allocator, "ssh", args, "install") == null);
}
