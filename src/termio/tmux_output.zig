const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const Data = @import("../datastruct/main.zig").MessageData(u8, 255);

const Output = @This();
const log = std.log.scoped(.tmux_output);

pub const max_chunk = 64 * 1024;

pane_id: usize,
data: Data,
budget: *Budget,
charge: usize,

/// Copy and reserve one output chunk. The renderer mutex must be held;
/// it is released while waiting for capacity and reacquired before returning.
/// Null means the gateway is shutting down. The receiver owns a returned chunk.
pub fn create(
    budget: *Budget,
    pane_id: usize,
    content: []const u8,
    renderer_mutex: *std.Io.Mutex,
) !?Output {
    const charge = @sizeOf(Output) + if (content.len > Data.Small.Max) content.len else 0;
    if (content.len > max_chunk or charge > budget.capacity) return error.OutputTooLarge;
    const data = try Data.init(budget.alloc, content);
    if (!budget.acquire(charge, renderer_mutex)) {
        data.deinit();
        return null;
    }
    budget.retain();
    return .{ .pane_id = pane_id, .data = data, .budget = budget, .charge = charge };
}

pub fn bytes(self: *const Output) []const u8 {
    return self.data.slice();
}

pub fn deinit(self: *const Output) void {
    self.data.deinit();
    self.budget.consume(self.charge);
    self.budget.release();
}

/// Shared by a gateway and all output it has handed to follower panes.
pub const Budget = struct {
    alloc: Allocator,
    capacity: usize,
    used: usize = 0,
    closed: bool = false,
    references: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    room: std.Io.Condition = .init,

    pub fn create(alloc: Allocator, capacity: usize) Allocator.Error!*Budget {
        const self = try alloc.create(Budget);
        self.* = .{ .alloc = alloc, .capacity = capacity };
        return self;
    }

    fn retain(self: *Budget) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *Budget) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.used == 0);
        self.alloc.destroy(self);
    }

    fn acquire(self: *Budget, charge: usize, renderer_mutex: *std.Io.Mutex) bool {
        var released_renderer = false;
        defer if (released_renderer) renderer_mutex.lockUncancelable(global.io());
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        while (!self.closed and self.used + charge > self.capacity) {
            if (!released_renderer) {
                log.debug("backpressure waiting queued={d} incoming={d}", .{ self.used, charge });
                renderer_mutex.unlock(global.io());
                released_renderer = true;
            }
            self.room.waitUncancelable(global.io(), &self.mutex);
        }
        if (released_renderer) log.debug("backpressure resumed queued={d} closed={}", .{ self.used, self.closed });
        if (self.closed) return false;
        self.used += charge;
        return true;
    }

    fn consume(self: *Budget, charge: usize) void {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        std.debug.assert(self.used >= charge);
        self.used -= charge;
        self.room.broadcast(global.io());
    }

    pub fn close(self: *Budget) void {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        self.closed = true;
        self.room.broadcast(global.io());
    }
};

test "tmux output backpressure releases the renderer and wakes on consumption or closure" {
    const testing = std.testing;
    const Producer = struct {
        budget: *Budget,
        renderer_mutex: *std.Io.Mutex,
        payload: []const u8,
        started: std.Io.Event = .unset,
        finished: std.atomic.Value(bool) = .init(false),
        output: ?Output = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.renderer_mutex.lockUncancelable(global.io());
            defer self.renderer_mutex.unlock(global.io());
            self.started.set(global.io());
            self.output = Output.create(self.budget, 7, self.payload, self.renderer_mutex) catch |err| failed: {
                self.failure = err;
                break :failed null;
            };
            self.finished.store(true, .release);
        }
    };
    const payload: [max_chunk]u8 = @splat(0xab);
    for ([_]bool{ false, true }) |close| {
        const budget = try Budget.create(testing.allocator, 2 * max_chunk);
        defer budget.release();
        var renderer_mutex: std.Io.Mutex = .init;
        renderer_mutex.lockUncancelable(global.io());
        var held = try Output.create(budget, 7, &payload, &renderer_mutex);
        renderer_mutex.unlock(global.io());
        defer if (held) |*output| output.deinit();
        var producer: Producer = .{ .budget = budget, .renderer_mutex = &renderer_mutex, .payload = &payload };
        const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
        producer.started.waitUncancelable(global.io());
        renderer_mutex.lockUncancelable(global.io());
        const blocked = !producer.finished.load(.acquire);
        if (close) {
            budget.close();
        } else {
            held.?.deinit();
            held = null;
        }
        renderer_mutex.unlock(global.io());
        thread.join();
        defer if (producer.output) |*output| output.deinit();
        try testing.expect(blocked);
        try testing.expect(producer.failure == null);
        if (close) {
            try testing.expect(producer.output == null);
        } else {
            try testing.expectEqualSlices(u8, &payload, producer.output.?.bytes());
        }
    }
}
