//! Per-view storage that grows with use, up to the same tripwire capacity a
//! fixed array would declare. A fixed array inline in `RuntimeView` costs a
//! resident page the first time anything touches it, even for a handful of
//! entries; this holds only what was asked for, in a heap that packs small
//! allocations from many views together.
//!
//! Growth moves the storage. A slice from `slice()` or `sliceMut()` is valid
//! until the next call that can grow the same array (`ensureCapacity`,
//! `replace`, `append`, `resize`) or `deinit`.
const std = @import("std");
const builtin = @import("builtin");

/// Where a view's `GrownArray` fields allocate (`RuntimeView.deinit` frees
/// them). It has to pack small allocations from many views densely: an
/// allocation per page would cost what the fixed arrays did. The C heap when
/// libc is linked (every desktop host build links it); otherwise Zig's
/// general-purpose `smp_allocator` (the null-platform tests, the no-libc
/// Android library), or the wasm allocator on wasm, where `smp_allocator`
/// has no threads to serve.
pub const storage_allocator: std.mem.Allocator = if (builtin.link_libc)
    std.heap.c_allocator
else if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.smp_allocator;

pub fn GrownArray(comptime T: type, comptime max_len: usize) type {
    return struct {
        const Self = @This();

        /// The tripwire. Growth past it is refused; callers check it first
        /// and answer with their own named budget error (or their own
        /// truncate/drop policy), exactly as with a fixed array.
        pub const max = max_len;
        /// The first allocation holds at least this many, so the first few
        /// appends do not each move the storage.
        pub const min_capacity = @min(4, max_len);

        /// Marks the type for `RuntimeView.deinit`, which frees every
        /// grown field by reflection so a new one cannot leak.
        pub const is_grown_array = true;

        pub const Error = error{ OutOfMemory, CapacityExceeded };

        /// Allocated storage: `items[0..len]` is live, the rest undefined.
        items: []T = &.{},
        len: usize = 0,

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.items[0..self.len];
        }

        /// Room for `count` entries without another allocation. Keeps the
        /// live prefix; never shrinks.
        pub fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, count: usize) Error!void {
            if (count <= self.items.len) return;
            const grown = try self.allocateFor(allocator, count);
            @memcpy(grown[0..self.len], self.items[0..self.len]);
            allocator.free(self.items);
            self.items = grown;
        }

        /// Make the live contents a copy of `entries`. `entries` may point
        /// into this array's own storage: new storage is allocated before
        /// the old is freed, and an in-place copy tolerates overlap.
        pub fn replace(self: *Self, allocator: std.mem.Allocator, entries: []const T) Error!void {
            if (entries.len > self.items.len) {
                const grown = try self.allocateFor(allocator, entries.len);
                @memcpy(grown[0..entries.len], entries);
                allocator.free(self.items);
                self.items = grown;
            } else {
                @memmove(self.items[0..entries.len], entries);
            }
            self.len = entries.len;
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) Error!void {
            try self.ensureCapacity(allocator, self.len + 1);
            self.appendAssumeCapacity(value);
        }

        pub fn appendAssumeCapacity(self: *Self, value: T) void {
            std.debug.assert(self.len < self.items.len);
            self.items[self.len] = value;
            self.len += 1;
        }

        /// Set the live length to `count`. Entries past the old length are
        /// undefined until written.
        pub fn resize(self: *Self, allocator: std.mem.Allocator, count: usize) Error!void {
            try self.ensureCapacity(allocator, count);
            self.len = count;
        }

        /// Empty the array and keep its capacity.
        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
            self.* = .{};
        }

        /// New storage for at least `count`: double the current capacity,
        /// or `count` if that is more, at least `min_capacity`, at most `max`.
        fn allocateFor(self: *const Self, allocator: std.mem.Allocator, count: usize) Error![]T {
            if (count > max) return error.CapacityExceeded;
            const capacity = @min(max, @max(count, self.items.len * 2, min_capacity));
            return allocator.alloc(T, capacity);
        }
    };
}

test "replace accepts entries from its own storage" {
    const gpa = std.testing.allocator;
    var array: GrownArray(u32, 16) = .{};
    defer array.deinit(gpa);

    try array.replace(gpa, &.{ 1, 2, 3, 4, 5, 6 });
    // The same storage, shifted down: an overlapping in-place copy.
    try array.replace(gpa, array.slice()[2..5]);
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5 }, array.slice());
    // Exactly its own contents.
    try array.replace(gpa, array.slice());
    try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5 }, array.slice());
}

test "replace that grows copies the entries before freeing the old storage" {
    const gpa = std.testing.allocator;
    var array: GrownArray(u32, 64) = .{};
    defer array.deinit(gpa);

    try array.replace(gpa, &.{ 7, 8 });
    const old_capacity = array.items.len;
    var bigger: [20]u32 = undefined;
    for (&bigger, 0..) |*value, index| value.* = @intCast(index);
    try array.replace(gpa, &bigger);
    try std.testing.expect(array.items.len > old_capacity);
    try std.testing.expectEqualSlices(u32, &bigger, array.slice());
}

test "grows by doubling up to max and refuses past it" {
    const gpa = std.testing.allocator;
    var array: GrownArray(u16, 10) = .{};
    defer array.deinit(gpa);

    var capacities: [10]usize = undefined;
    for (0..10) |index| {
        try array.append(gpa, @intCast(index));
        capacities[index] = array.items.len;
    }
    try std.testing.expectEqualSlices(usize, &.{ 4, 4, 4, 4, 8, 8, 8, 8, 10, 10 }, &capacities);

    try std.testing.expectError(error.CapacityExceeded, array.append(gpa, 10));
    try std.testing.expectError(error.CapacityExceeded, array.ensureCapacity(gpa, 11));
    var eleven: [11]u16 = @splat(0);
    try std.testing.expectError(error.CapacityExceeded, array.replace(gpa, &eleven));
    // A refusal changes nothing.
    try std.testing.expectEqual(@as(usize, 10), array.len);
    for (array.slice(), 0..) |value, index| try std.testing.expectEqual(@as(u16, @intCast(index)), value);
}

test "a failed allocation is an error and leaves the contents intact" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();
    var array: GrownArray(u8, 100) = .{};
    defer array.deinit(gpa);

    try array.replace(gpa, "abc");
    try std.testing.expectError(error.OutOfMemory, array.replace(gpa, "abcdefghij"));
    try std.testing.expectError(error.OutOfMemory, array.ensureCapacity(gpa, 50));
    try std.testing.expectEqualStrings("abc", array.slice());
}

test "clear keeps the capacity, so refilling it allocates nothing" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();
    var array: GrownArray(u64, 32) = .{};
    defer array.deinit(gpa);

    try array.resize(gpa, 8);
    const capacity = array.items.len;
    array.clear();
    try std.testing.expectEqual(@as(usize, 0), array.len);
    try std.testing.expectEqual(capacity, array.items.len);
    // Every allocation after the first fails, so these must fit as is.
    for (0..capacity) |index| try array.append(gpa, index);
    try std.testing.expectEqual(capacity, array.len);
}

test "deinit frees the storage and leaves an empty array" {
    const gpa = std.testing.allocator;
    var array: GrownArray(u32, 8) = .{};
    try array.replace(gpa, &.{ 1, 2, 3 });
    array.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), array.len);
    try std.testing.expectEqual(@as(usize, 0), array.items.len);
    // Usable again after deinit; the testing allocator reports any leak.
    try array.append(gpa, 4);
    array.deinit(gpa);
}
