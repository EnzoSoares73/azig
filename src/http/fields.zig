const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

/// Iterates over every value of one name in a list of fields.
pub const ValueIterator = struct {
    items: []const Field,
    name: []const u8,
    index: usize = 0,

    pub fn next(it: *ValueIterator) ?[]const u8 {
        while (it.index < it.items.len) {
            const field = it.items[it.index];
            it.index += 1;
            if (mem.eql(u8, field.name, it.name)) return field.value;
        }
        return null;
    }
};

/// Ordered name/value pairs (headers, query parameters). Repeated names are kept. Names are
/// matched exactly: request header names are stored in canonical form (`Content-Length`).
/// Only the list is owned; names and values are borrowed.
pub const Fields = struct {
    allocator: Allocator,
    list: std.ArrayList(Field) = .empty,

    const max_retained = 64;

    pub fn init(allocator: Allocator) Fields {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Fields) void {
        self.list.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *const Fields, name: []const u8) ?[]const u8 {
        for (self.list.items) |field| {
            if (mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }

    pub fn getAll(self: *const Fields, name: []const u8) ValueIterator {
        return .{ .items = self.list.items, .name = name };
    }

    pub fn append(self: *Fields, name: []const u8, value: []const u8) Allocator.Error!void {
        try self.list.append(self.allocator, .{ .name = name, .value = value });
    }

    pub fn put(self: *Fields, name: []const u8, value: []const u8) Allocator.Error!void {
        var found = false;
        var i: usize = 0;
        while (i < self.list.items.len) {
            if (mem.eql(u8, self.list.items[i].name, name)) {
                if (found) {
                    _ = self.list.orderedRemove(i);
                    continue;
                }
                self.list.items[i].value = value;
                found = true;
            }
            i += 1;
        }
        if (!found) try self.append(name, value);
    }

    pub fn count(self: *const Fields) usize {
        return self.list.items.len;
    }

    pub fn items(self: *const Fields) []const Field {
        return self.list.items;
    }

    pub fn clear(self: *Fields) void {
        self.list.clearRetainingCapacity();
    }

    /// Empties the list for reuse, keeping its capacity unless it grew unusually large.
    pub fn reset(self: *Fields) void {
        if (self.list.capacity > max_retained) {
            self.list.clearAndFree(self.allocator);
        } else {
            self.list.clearRetainingCapacity();
        }
    }
};

const testing = std.testing;

test "get returns the first value and getAll every value, matching names exactly" {
    var fields = Fields.init(testing.allocator);
    defer fields.deinit();

    try fields.append("Set-Cookie", "a=1");
    try fields.append("Content-Type", "text/plain");
    try fields.append("Set-Cookie", "b=2");

    try testing.expectEqualStrings("a=1", fields.get("Set-Cookie").?);
    try testing.expectEqual(@as(?[]const u8, null), fields.get("set-cookie"));

    var it = fields.getAll("Set-Cookie");
    try testing.expectEqualStrings("a=1", it.next().?);
    try testing.expectEqualStrings("b=2", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
}

test "put replaces every value of a name, or appends it" {
    var fields = Fields.init(testing.allocator);
    defer fields.deinit();

    try fields.put("X-A", "1");
    try fields.append("X-B", "2");
    try fields.append("X-A", "3");
    try fields.put("X-A", "4");

    try testing.expectEqual(@as(usize, 2), fields.count());
    try testing.expectEqualStrings("X-A", fields.items()[0].name);
    try testing.expectEqualStrings("4", fields.items()[0].value);
    try testing.expectEqualStrings("X-B", fields.items()[1].name);
}

test "reset keeps a small list's capacity and frees a large one" {
    var fields = Fields.init(testing.allocator);
    defer fields.deinit();

    try fields.append("X", "1");
    fields.reset();
    try testing.expectEqual(@as(usize, 0), fields.count());
    try testing.expect(fields.list.capacity > 0);

    for (0..Fields.max_retained + 1) |_| try fields.append("X", "1");
    fields.reset();
    try testing.expectEqual(@as(usize, 0), fields.list.capacity);
}
