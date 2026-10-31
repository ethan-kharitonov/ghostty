const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("terminal/main.zig");
const Program = terminal.osc.program_status;

const SessionStatus = @This();

records: std.StringArrayHashMapUnmanaged(Record) = .empty,
iterm: ITerm = .{},
serial: u64 = 0,

const Record = struct {
    report: Program.Report,
    serial: u64,

    fn deinit(self: Record, alloc: Allocator) void {
        alloc.free(self.report.data);
    }
};

const ITerm = struct {
    arena: ?std.heap.ArenaAllocator = null,
    label: []const u8 = "",
    detail: []const u8 = "",
    indicator: u32 = 0,
    text_color: u32 = 0,
    serial: u64 = 0,

    fn deinit(self: *ITerm) void {
        if (self.arena) |*arena| arena.deinit();
    }
};

/// The selected status, independent of either reporting protocol.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    label: [:0]const u8,
    detail: [:0]const u8,
    indicator: u32,
    text_color: u32,
    priority: u8,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};

pub fn deinit(self: *SessionStatus, alloc: Allocator) void {
    for (self.records.values()) |record| record.deinit(alloc);
    self.records.deinit(alloc);
    self.iterm.deinit();
    self.* = .{};
}

pub fn updateProgram(self: *SessionStatus, alloc: Allocator, report: Program.Report) !void {
    const id = report.readOption(.id) orelse "";
    if (report.state == .clear) {
        var index = self.records.count();
        while (index > 0) {
            index -= 1;
            const key = self.records.keys()[index];
            if (id.len == 0 or std.mem.eql(u8, id, key) or
                (std.mem.startsWith(u8, key, id) and key.len > id.len and key[id.len] == '/'))
                self.remove(alloc, index);
        }
        return;
    }

    const body = try alloc.dupe(u8, report.data);
    errdefer alloc.free(body);
    const owned: Program.Report = .{ .state = report.state, .data = body };
    try self.records.ensureTotalCapacity(alloc, @min(256, self.records.count() + 1));
    if (self.records.count() == 256 and !self.records.contains(id)) {
        var oldest: usize = 0;
        for (self.records.values(), 0..) |record, index| {
            if (record.serial < self.records.values()[oldest].serial) oldest = index;
        }
        self.remove(alloc, oldest);
    }

    const entry = self.records.getOrPutAssumeCapacity(owned.readOption(.id) orelse "");
    if (entry.found_existing) entry.value_ptr.deinit(alloc);
    self.serial += 1;
    entry.key_ptr.* = owned.readOption(.id) orelse "";
    entry.value_ptr.* = .{ .report = owned, .serial = self.serial };
}

/// OSC 21337 patches individual fields; omitted fields retain their values.
pub fn updateITerm(self: *SessionStatus, alloc: Allocator, body: []const u8) !void {
    var next = self.iterm;
    var changed = false;
    var fields = std.mem.splitScalar(u8, body, ';');
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..separator];
        const value = field[separator + 1 ..];
        if (std.mem.eql(u8, key, "indicator")) {
            next.indicator = parseColor(value) orelse continue;
            changed = true;
        } else if (std.mem.eql(u8, key, "status-color")) {
            next.text_color = parseColor(value) orelse continue;
            changed = true;
        } else if (validText(value)) {
            if (std.mem.eql(u8, key, "status")) {
                next.label = value;
                changed = true;
            }
            if (std.mem.eql(u8, key, "detail")) {
                next.detail = value;
                changed = true;
            }
        }
    }
    if (!changed) return;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    next.label = try arena.allocator().dupe(u8, next.label);
    next.detail = try arena.allocator().dupe(u8, next.detail);
    self.serial += 1;
    next.serial = self.serial;
    next.arena = arena;
    self.iterm.deinit();
    self.iterm = next;
}

/// A prompt or process exit ends transient reports, while results remain visible.
pub fn endCommand(self: *SessionStatus, alloc: Allocator) void {
    var index = self.records.count();
    while (index > 0) {
        index -= 1;
        switch (self.records.values()[index].report.state) {
            .working, .blocked => self.remove(alloc, index),
            else => {},
        }
    }
}

pub fn snapshot(self: *const SessionStatus, alloc: Allocator) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const strings = arena.allocator();
    var priority: u8 = if (self.iterm.label.len > 0 or self.iterm.indicator != 0)
        statusPriority(self.iterm.label)
    else
        0;
    var serial = self.iterm.serial;
    var selected: ?usize = null;
    for (self.records.values(), 0..) |record, index| {
        const rank = statusPriority(@tagName(record.report.state));
        if (rank > priority or (rank == priority and record.serial > serial)) {
            priority = rank;
            serial = record.serial;
            selected = index;
        }
    }

    if (selected) |index| {
        const report = self.records.values()[index].report;
        const label = if (report.readOption(.progress)) |progress|
            try std.fmt.allocPrintSentinel(strings, "{s} {d}%", .{ @tagName(report.state), progress }, 0)
        else
            try strings.dupeSentinel(u8, @tagName(report.state), 0);
        var detail: std.Io.Writer.Allocating = .init(strings);
        if (self.inheritedApp(self.records.keys()[index])) |app| {
            try detail.writer.writeAll(app);
        }
        inline for (.{ .title, .msg }) |option| {
            if (report.readOption(option) != null) {
                if (detail.written().len > 0) try detail.writer.writeAll(" — ");
                try report.writeText(option, &detail.writer);
            }
        }
        const color: u32 = switch (report.state) {
            .idle => 0x808080ff,
            .working => 0xffa500ff,
            .done => 0x39b54aff,
            .blocked => 0x3b82f6ff,
            .@"error" => 0xef4444ff,
            .clear => unreachable,
        };
        const description = try strings.dupeSentinel(u8, detail.written(), 0);
        return .{
            .arena = arena,
            .label = label,
            .detail = description,
            .indicator = color,
            .text_color = color,
            .priority = priority,
        };
    }
    const label = try strings.dupeSentinel(u8, self.iterm.label, 0);
    const detail = try strings.dupeSentinel(u8, self.iterm.detail, 0);
    return .{
        .arena = arena,
        .label = label,
        .detail = detail,
        .indicator = self.iterm.indicator,
        .text_color = self.iterm.text_color,
        .priority = priority,
    };
}

fn inheritedApp(self: *const SessionStatus, id: []const u8) ?[]const u8 {
    var ancestor = id;
    while (true) {
        if (self.records.get(ancestor)) |record| {
            if (record.report.readOption(.app)) |app| return app;
        }
        if (ancestor.len == 0) return null;
        ancestor = ancestor[0..(std.mem.lastIndexOfScalar(u8, ancestor, '/') orelse 0)];
    }
}

fn remove(self: *SessionStatus, alloc: Allocator, index: usize) void {
    const record = self.records.values()[index];
    self.records.swapRemoveAt(index);
    record.deinit(alloc);
}

fn statusPriority(label: []const u8) u8 {
    const labels = .{ "idle", "done", "background", "working", "error", "blocked" };
    inline for (labels, 1..) |name, priority| {
        if (std.ascii.eqlIgnoreCase(label, name)) return priority;
    }
    if (std.ascii.eqlIgnoreCase(label, "waiting")) return 6;
    return 1;
}

fn parseColor(value: []const u8) ?u32 {
    if (value.len == 0) return 0;
    const rgb = terminal.color.RGB.parse(value) catch return null;
    return (@as(u32, rgb.r) << 24) | (@as(u32, rgb.g) << 16) | (@as(u32, rgb.b) << 8) | 255;
}

fn validText(value: []const u8) bool {
    const text = std.unicode.Utf8View.init(value) catch return false;
    var codepoints = text.iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return false;
    }
    return true;
}

test "SessionStatus iterm patches retain omitted fields and clear empty fields" {
    const alloc = std.testing.allocator;
    var state: SessionStatus = .{};
    defer state.deinit(alloc);
    try state.updateITerm(alloc, "status=working;indicator=#ffa500;detail=Building");
    try state.updateITerm(alloc, "status=waiting;status-color=rgb:11/22/33");
    var waiting = try state.snapshot(alloc);
    defer waiting.deinit();
    try std.testing.expectEqualStrings("waiting", waiting.label);
    try std.testing.expectEqualStrings("Building", waiting.detail);
    try std.testing.expectEqual(@as(u32, 0xffa500ff), waiting.indicator);
    try std.testing.expectEqual(@as(u32, 0x112233ff), waiting.text_color);
    try state.updateITerm(alloc, "status=;indicator=");
    var cleared = try state.snapshot(alloc);
    defer cleared.deinit();
    try std.testing.expectEqualStrings("", cleared.label);
    try std.testing.expectEqual(@as(u32, 0), cleared.indicator);
    try std.testing.expectEqualStrings("Building", cleared.detail);
}

test "SessionStatus program replacement inherits the nearest application" {
    const alloc = std.testing.allocator;
    var state: SessionStatus = .{};
    defer state.deinit(alloc);
    try state.updateProgram(alloc, .{ .state = .idle, .data = "state=idle:app=codex" });
    try state.updateProgram(alloc, .{ .state = .blocked, .data = "state=blocked:id=build/test:msg=TmVlZCBpbnB1dA==" });
    var blocked = try state.snapshot(alloc);
    defer blocked.deinit();
    try std.testing.expectEqualStrings("blocked", blocked.label);
    try std.testing.expectEqualStrings("codex — Need input", blocked.detail);
    try state.updateProgram(alloc, .{ .state = .working, .data = "state=working:id=build/test:progress=40" });
    var working = try state.snapshot(alloc);
    defer working.deinit();
    try std.testing.expectEqualStrings("working 40%", working.label);
    try std.testing.expectEqualStrings("codex", working.detail);
}

test "SessionStatus clearing a subtree preserves similarly named siblings" {
    const alloc = std.testing.allocator;
    var state: SessionStatus = .{};
    defer state.deinit(alloc);
    try state.updateProgram(alloc, .{ .state = .blocked, .data = "state=blocked:id=build/test" });
    try state.updateProgram(alloc, .{ .state = .done, .data = "state=done:id=build-tools" });
    try state.updateProgram(alloc, .{ .state = .clear, .data = "state=clear:id=build" });
    var result = try state.snapshot(alloc);
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.label);
}

test "SessionStatus prompts end transient work while retaining results" {
    const alloc = std.testing.allocator;
    var state: SessionStatus = .{};
    defer state.deinit(alloc);
    try state.updateProgram(alloc, .{ .state = .blocked, .data = "state=blocked:id=question" });
    try state.updateProgram(alloc, .{ .state = .working, .data = "state=working:id=worker" });
    try state.updateProgram(alloc, .{ .state = .done, .data = "state=done:id=result" });
    state.endCommand(alloc);
    var result = try state.snapshot(alloc);
    defer result.deinit();
    try std.testing.expectEqualStrings("done", result.label);
    try state.updateProgram(alloc, .{ .state = .clear, .data = "state=clear" });
    var empty = try state.snapshot(alloc);
    defer empty.deinit();
    try std.testing.expectEqualStrings("", empty.label);
}

test "SessionStatus evicts the least recently updated record at capacity" {
    const alloc = std.testing.allocator;
    var state: SessionStatus = .{};
    defer state.deinit(alloc);
    try state.updateProgram(alloc, .{ .state = .blocked, .data = "state=blocked:id=oldest" });
    for (0..256) |index| {
        var buffer: [64]u8 = undefined;
        const body = try std.mem.print(&buffer, "state=idle:id=record{d}", .{index});
        try state.updateProgram(alloc, .{ .state = .idle, .data = body });
    }
    var result = try state.snapshot(alloc);
    defer result.deinit();
    try std.testing.expectEqualStrings("idle", result.label);
    try state.updateProgram(alloc, .{ .state = .blocked, .data = "state=blocked:id=record0" });
    try state.updateProgram(alloc, .{ .state = .idle, .data = "state=idle:id=additional" });
    var refreshed = try state.snapshot(alloc);
    defer refreshed.deinit();
    try std.testing.expectEqualStrings("blocked", refreshed.label);
}
