const std = @import("std");
const Allocator = std.mem.Allocator;

/// Read window groups from Ghostty or iTerm2, discarding client-specific
/// identifiers and window options. The caller owns the outer and inner slices.
pub fn parse(alloc: Allocator, encoded: []const u8) ![][]usize {
    const decoded: ?[]u8 = if (std.mem.startsWith(u8, encoded, "a_")) decode: {
        const bytes = try alloc.alloc(u8, (encoded.len - 2) / 2);
        errdefer alloc.free(bytes);
        break :decode try std.fmt.hexToBytes(bytes, encoded[2..]);
    } else null;
    defer if (decoded) |bytes| alloc.free(bytes);

    var groups: std.ArrayList([]usize) = .empty;
    errdefer {
        for (groups.items) |group| alloc.free(group);
        groups.deinit(alloc);
    }
    var seen: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer seen.deinit(alloc);
    var entries = std.mem.tokenizeAny(u8, decoded orelse encoded, " |");
    while (entries.next()) |entry| {
        const members = entry[0..(std.mem.indexOfScalar(u8, entry, ';') orelse entry.len)];
        var ids = std.mem.tokenizeScalar(u8, members, ',');
        var group: std.ArrayList(usize) = .empty;
        defer group.deinit(alloc);
        while (ids.next()) |text| {
            const id = std.fmt.parseInt(usize, text, 10) catch continue;
            const stored = try seen.getOrPut(alloc, id);
            if (stored.found_existing) continue;
            try group.append(alloc, id);
        }
        if (group.items.len == 0) continue;
        const owned = try group.toOwnedSlice(alloc);
        errdefer alloc.free(owned);
        try groups.append(alloc, owned);
    }
    return groups.toOwnedSlice(alloc);
}

test "tmux affinity imports encoded iTerm groups and ignores their metadata" {
    const alloc = std.testing.allocator;
    const groups = try parse(alloc, "a_312c322c7074792d6162633b57696e646f775374796c653d46756c6c53637265656e20332c7074792d6465663b");
    defer {
        for (groups) |group| alloc.free(group);
        alloc.free(groups);
    }
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, groups[0]);
    try std.testing.expectEqualSlices(usize, &.{3}, groups[1]);
}

test "tmux affinity places each window in only one group" {
    const alloc = std.testing.allocator;
    const groups = try parse(alloc, "1,2,1|2,3 4");
    defer {
        for (groups) |group| alloc.free(group);
        alloc.free(groups);
    }
    try std.testing.expectEqual(@as(usize, 3), groups.len);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, groups[0]);
    try std.testing.expectEqualSlices(usize, &.{3}, groups[1]);
    try std.testing.expectEqualSlices(usize, &.{4}, groups[2]);
}
