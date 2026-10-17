//! Fixed-capacity storage that pays commit only for the pages it touches.
//!
//! Native sizes its tables as tripwires: a `Runtime` holds 32 views of
//! 1,024 layout nodes each, the canvas planner's scratch thousands of
//! commands. On macOS and Linux an anonymous mapping costs nothing until a
//! page is touched, so `page_allocator.create(T)` is already lazy there.
//! Windows has no overcommit: `page_allocator` reserves and commits in one
//! call, and every committed byte counts against the system's commit limit
//! (Task Manager's "Commit size", Process Explorer's "Private Bytes")
//! whether or not it is ever touched. Receipt (Weaver widget host, 10
//! clocks, 2026-10-17): one `Runtime` committed 97,300 KiB and kept
//! 712 KiB resident; the canvas scratch 2,664 KiB for 44 KiB resident.
//!
//! `create` reserves instead, and a vectored exception handler commits a
//! page the first time user-mode code touches it. A committed page arrives
//! zeroed, as `page_allocator`'s do. Each page faults once; after that it
//! is ordinary memory.
//!
//! The kernel does not raise that fault for us: a system call that WRITES
//! into a page nothing has touched fails (ERROR_NOACCESS, 998) instead of
//! committing it. Before handing part of such an object to the kernel as an
//! output buffer, `commit` that part. Reading what user code wrote is fine:
//! writing it committed it.
//!
//! A debugger shows each first touch as a first-chance access violation.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const lazy = builtin.os.tag == .windows;
const page_size = std.heap.page_size_min;

/// Reservations the handler may commit into. A tripwire: a Weaver widget
/// host holds one `Runtime`, one app, a canvas scratch per rendering
/// thread, and two per widget (at most 32 widgets), so under 80. Past it,
/// `create` commits eagerly as `page_allocator` does, and says so once.
pub const max_reservations = 256;

var bases: [max_reservations]std.atomic.Value(usize) = @splat(.init(0));
var lengths: [max_reservations]usize = @splat(0);
var table_lock: windows.SRWLOCK = .{};
var handler: ?*anyopaque = null;
var warned_full = false;

/// A `T` whose pages are committed as they are touched (on Windows; other
/// systems already behave so, and get `page_allocator`'s). Its contents
/// start zeroed on Windows and undefined elsewhere, like `create`'s.
pub fn create(comptime T: type) error{OutOfMemory}!*T {
    if (!lazy or @sizeOf(T) < 64 * 1024) return std.heap.page_allocator.create(T);
    comptime std.debug.assert(@alignOf(T) <= 64 * 1024);
    const bytes = std.mem.alignForward(usize, @sizeOf(T), page_size);
    const base = VirtualAlloc(null, bytes, mem_reserve, page_noaccess) orelse return error.OutOfMemory;
    if (!track(@intFromPtr(base), bytes)) {
        _ = VirtualFree(base, 0, mem_release);
        return std.heap.page_allocator.create(T);
    }
    return @ptrCast(@alignCast(base));
}

/// Free what `create` returned.
pub fn destroy(ptr: anytype) void {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    if (!lazy or @sizeOf(T) < 64 * 1024 or !untrack(@intFromPtr(ptr))) return std.heap.page_allocator.destroy(ptr);
    _ = VirtualFree(@ptrCast(ptr), 0, mem_release);
}

/// Commit `bytes` now, for a system call that will write into them (see
/// the file comment). Memory not from `create` is already committed.
pub fn commit(bytes: []u8) error{OutOfMemory}!void {
    if (!lazy or bytes.len == 0) return;
    if (VirtualAlloc(bytes.ptr, bytes.len, mem_commit, page_readwrite) == null) return error.OutOfMemory;
}

fn track(base: usize, length: usize) bool {
    AcquireSRWLockExclusive(&table_lock);
    defer ReleaseSRWLockExclusive(&table_lock);
    if (handler == null) {
        // First in line: Zig's segfault handler, where installed, is last.
        handler = windows.ntdll.RtlAddVectoredExceptionHandler(1, onFault);
        if (handler == null) return false;
    }
    for (&bases, &lengths) |*slot, *slot_length| {
        if (slot.load(.monotonic) != 0) continue;
        slot_length.* = length;
        slot.store(base, .release);
        return true;
    }
    if (!warned_full) {
        warned_full = true;
        std.log.warn("lazy_commit: max_reservations={d} reached; further fixed tables are committed whole", .{max_reservations});
    }
    return false;
}

fn untrack(base: usize) bool {
    AcquireSRWLockExclusive(&table_lock);
    defer ReleaseSRWLockExclusive(&table_lock);
    for (&bases) |*slot| {
        if (slot.load(.monotonic) != base) continue;
        slot.store(0, .release);
        return true;
    }
    return false;
}

fn owned(address: usize) bool {
    for (&bases, lengths) |*slot, length| {
        const base = slot.load(.acquire);
        if (base != 0 and address >= base and address - base < length) return true;
    }
    return false;
}

/// A read or write of a reserved page in one of our reservations: commit
/// that page and retry the instruction. Anything else is not ours.
fn onFault(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const record = info.ExceptionRecord;
    if (record.ExceptionCode != windows.EXCEPTION_ACCESS_VIOLATION or record.NumberParameters < 2) return windows.EXCEPTION_CONTINUE_SEARCH;
    // 0 is a read, 1 a write; 8 (execution) is never ours.
    if (record.ExceptionInformation[0] > 1) return windows.EXCEPTION_CONTINUE_SEARCH;
    const address = record.ExceptionInformation[1];
    if (!owned(address)) return windows.EXCEPTION_CONTINUE_SEARCH;
    const page = std.mem.alignBackward(usize, address, page_size);
    // Out of commit: the access fails as it would have without us.
    if (VirtualAlloc(@ptrFromInt(page), page_size, mem_commit, page_readwrite) == null) return windows.EXCEPTION_CONTINUE_SEARCH;
    return exception_continue_execution;
}

const exception_continue_execution: c_long = -1;
const mem_commit: u32 = 0x1000;
const mem_reserve: u32 = 0x2000;
const mem_release: u32 = 0x8000;
const page_noaccess: u32 = 0x01;
const page_readwrite: u32 = 0x04;
extern "kernel32" fn VirtualAlloc(address: ?*anyopaque, size: usize, kind: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(address: ?*anyopaque, size: usize, kind: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *windows.SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *windows.SRWLOCK) callconv(.winapi) void;

const ProcessMemoryCounters = extern struct {
    cb: u32,
    page_fault_count: u32,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
    private_usage: usize,
};
extern "kernel32" fn K32GetProcessMemoryInfo(process: windows.HANDLE, counters: *ProcessMemoryCounters, size: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;

fn committedBytes() usize {
    var counters = std.mem.zeroes(ProcessMemoryCounters);
    counters.cb = @sizeOf(ProcessMemoryCounters);
    _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb);
    return counters.private_usage;
}

test "a large table commits only the pages it touches, zeroed" {
    if (!lazy) return error.SkipZigTest;
    const Table = struct { cells: [64 * 1024 * 1024]u8 };
    const before = committedBytes();
    const table = try create(Table);
    defer destroy(table);
    // Reserved, not committed: the 64 MiB is not charged.
    try std.testing.expect(committedBytes() -| before < 1024 * 1024);
    table.cells[0] = 7;
    table.cells[40 * 1024 * 1024 + 5] = 9;
    try std.testing.expectEqual(@as(u8, 0), table.cells[12 * 1024 * 1024]);
    try std.testing.expectEqual(@as(u8, 7), table.cells[0]);
    try std.testing.expectEqual(@as(u8, 9), table.cells[40 * 1024 * 1024 + 5]);
    // Three pages touched (two written, one read): still well under 1 MiB.
    try std.testing.expect(committedBytes() -| before < 1024 * 1024);
}

test "the kernel writes into a table only where it is committed" {
    if (!lazy) return error.SkipZigTest;
    const Table = struct { cells: [1024 * 1024]u8 };
    const table = try create(Table);
    defer destroy(table);
    var path: [1024:0]u16 = undefined;
    const length = GetModuleFileNameW(null, &path, path.len);
    try std.testing.expect(length > 0 and length < path.len);
    path[length] = 0;
    const file = CreateFileW(&path, 0x8000_0000, 0x1 | 0x4, null, 3, 0, null);
    try std.testing.expect(file != windows.INVALID_HANDLE_VALUE);
    defer _ = CloseHandle(file);
    const buffer = table.cells[512 * 1024 ..][0 .. 3 * page_size];
    var read: u32 = 0;
    // Nothing touched these pages: the kernel's write fails, it does not fault.
    try std.testing.expect(!ReadFile(file, buffer.ptr, @intCast(buffer.len), &read, null).toBool());
    try std.testing.expectEqual(@as(u32, 998), GetLastError());
    try commit(buffer);
    _ = SetFilePointerEx(file, 0, null, 0);
    try std.testing.expect(ReadFile(file, buffer.ptr, @intCast(buffer.len), &read, null).toBool());
    try std.testing.expectEqual(@as(u32, @intCast(buffer.len)), read);
    try std.testing.expectEqualSlices(u8, "MZ", buffer[0..2]);
}

test "memory not from create passes through" {
    const Small = struct { value: u32 };
    const small = try create(Small);
    small.value = 3;
    destroy(small);
    var stack_bytes: [16]u8 = undefined;
    try commit(&stack_bytes);
}

extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, name: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn ReadFile(file: windows.HANDLE, buffer: [*]u8, bytes: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetFilePointerEx(file: windows.HANDLE, distance: i64, new_position: ?*i64, method: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
