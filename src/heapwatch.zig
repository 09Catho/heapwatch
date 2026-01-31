const std = @import("std");

pub const Config = struct {
    capture: CaptureMode = .light,
    tracker_limit: usize = 0, // 0 means unlimited
};

pub const CaptureMode = enum {
    none,
    light,
    source,
};

pub const AllocationRecord = struct {
    ptr: usize,
    size: usize,
    alignment: u8,
    timestamp: usize,
    ret_addr: usize,
    src_loc: ?std.builtin.SourceLocation = null,
};

const LeakGroup = struct {
    id: u64, // fingerprint
    src_loc: ?std.builtin.SourceLocation,
    ret_addr: usize,
    count: usize,
    bytes: usize,
};

fn greaterThanLeakGroup(context: void, a: LeakGroup, b: LeakGroup) bool {
    _ = context;
    if (a.bytes != b.bytes) return a.bytes > b.bytes;
    return a.count > b.count;
}

pub const HeapWatchAllocator = struct {
    child_allocator: std.mem.Allocator,
    config: Config,

    // Internal state
    allocations: std.AutoHashMap(usize, AllocationRecord),
    mutex: std.Thread.Mutex = .{},
    event_counter: usize = 0,

    // Counters
    total_allocated: usize = 0,
    total_freed: usize = 0,
    peak_allocated: usize = 0,
    current_allocated: usize = 0,
    alloc_count: usize = 0,
    free_count: usize = 0,

    pub fn init(child_allocator: std.mem.Allocator, config: Config) HeapWatchAllocator {
        return HeapWatchAllocator{
            .child_allocator = child_allocator,
            .config = config,
            .allocations = std.AutoHashMap(usize, AllocationRecord).init(child_allocator),
        };
    }

    pub fn allocator(self: *HeapWatchAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *HeapWatchAllocator = @ptrCast(@alignCast(ctx));

        const ptr = self.child_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;
        const ptr_addr = @intFromPtr(ptr);

        self.mutex.lock();
        defer self.mutex.unlock();

        self.event_counter += 1;
        self.alloc_count += 1;
        self.total_allocated += len;
        self.current_allocated += len;
        if (self.current_allocated > self.peak_allocated) {
            self.peak_allocated = self.current_allocated;
        }

        if (self.config.tracker_limit > 0 and self.allocations.count() >= self.config.tracker_limit) {
            // Limit reached
        } else {
            self.allocations.put(ptr_addr, .{
                .ptr = ptr_addr,
                .size = len,
                .alignment = ptr_align,
                .timestamp = self.event_counter,
                .ret_addr = ret_addr,
                .src_loc = null,
            }) catch {};
        }

        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *HeapWatchAllocator = @ptrCast(@alignCast(ctx));

        if (self.child_allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
            self.mutex.lock();
            defer self.mutex.unlock();

            const ptr_addr = @intFromPtr(buf.ptr);
            const old_len = buf.len;

            if (new_len > old_len) {
                const diff = new_len - old_len;
                self.total_allocated += diff;
                self.current_allocated += diff;
                if (self.current_allocated > self.peak_allocated) {
                    self.peak_allocated = self.current_allocated;
                }
            } else {
                const diff = old_len - new_len;
                self.total_freed += diff;
                self.current_allocated -= diff;
            }

            if (self.allocations.getPtr(ptr_addr)) |rec| {
                rec.size = new_len;
            }
            return true;
        }
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *HeapWatchAllocator = @ptrCast(@alignCast(ctx));

        self.mutex.lock();

        const ptr_addr = @intFromPtr(buf.ptr);
        const removed = self.allocations.remove(ptr_addr);

        self.event_counter += 1;
        self.free_count += 1;
        self.total_freed += buf.len;
        self.current_allocated -= buf.len;

        self.mutex.unlock();

        if (!removed) {
            // Double free or untracked
        }

        self.child_allocator.rawFree(buf, buf_align, ret_addr);
    }

    // --- Helper API for source capture ---

    pub fn allocWithSrc(self: *HeapWatchAllocator, comptime T: type, n: usize, src: std.builtin.SourceLocation) ![]T {
        const slice = try self.allocator().alloc(T, n);
        self.setSource(slice.ptr, src);
        return slice;
    }

    pub fn createWithSrc(self: *HeapWatchAllocator, comptime T: type, src: std.builtin.SourceLocation) !*T {
        const ptr = try self.allocator().create(T);
        self.setSource(ptr, src);
        return ptr;
    }

    fn setSource(self: *HeapWatchAllocator, ptr: anytype, src: std.builtin.SourceLocation) void {
        const ptr_addr = @intFromPtr(ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.allocations.getPtr(ptr_addr)) |rec| {
            rec.src_loc = src;
        }
    }

    pub const ReportOptions = struct {
        format: enum { human, json } = .human,
        top: usize = 20,
    };

    fn getLeakGroups(self: *HeapWatchAllocator) std.ArrayList(LeakGroup) {
        var groups = std.AutoHashMap(u64, LeakGroup).init(self.child_allocator);
        defer groups.deinit();

        var iter = self.allocations.iterator();
        while (iter.next()) |entry| {
            const rec = entry.value_ptr;
            var fingerprint: u64 = 0;
            if (rec.src_loc) |loc| {
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(loc.file);
                hasher.update(loc.fn_name);
                hasher.update(std.mem.asBytes(&loc.line));
                fingerprint = hasher.final();
            } else {
                fingerprint = rec.ret_addr;
            }

            const g = groups.getOrPut(fingerprint) catch continue;
            if (!g.found_existing) {
                g.value_ptr.* = .{ .id = fingerprint, .src_loc = rec.src_loc, .ret_addr = rec.ret_addr, .count = 0, .bytes = 0 };
            }
            g.value_ptr.count += 1;
            g.value_ptr.bytes += rec.size;
        }

        var list = std.ArrayList(LeakGroup).init(self.child_allocator);
        var g_iter = groups.iterator();
        while (g_iter.next()) |entry| {
            list.append(entry.value_ptr.*) catch {};
        }
        std.mem.sort(LeakGroup, list.items, {}, greaterThanLeakGroup);
        return list;
    }

    pub fn writeReport(self: *HeapWatchAllocator, writer: anytype, options: ReportOptions) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const leaked_count = self.allocations.count();
        const leaked_bytes = self.current_allocated;

        if (options.format == .human) {
            try writer.print("\n=== HeapWatch Report ===\n", .{});
            try writer.print("Total Allocated: {d} bytes ({d} allocs)\n", .{ self.total_allocated, self.alloc_count });
            try writer.print("Total Freed:     {d} bytes ({d} frees)\n", .{ self.total_freed, self.free_count });
            try writer.print("Peak Allocated:  {d} bytes\n", .{self.peak_allocated});
            try writer.print("Current Leaks:   {d} bytes ({d} allocs)\n", .{ leaked_bytes, leaked_count });

            if (leaked_count > 0) {
                var list = self.getLeakGroups();
                defer list.deinit();

                try writer.print("\nTop Leaks by Callsite:\n", .{});
                try writer.print("{s:<40} | {s:<10} | {s:<10}\n", .{ "Location", "Bytes", "Count" });
                try writer.print("{s:-<40}-+-{s:-<10}-+-{s:-<10}\n", .{ "", "", "" });

                var count: usize = 0;
                for (list.items) |g| {
                    if (count >= options.top) break;

                    if (g.src_loc) |loc| {
                        try writer.print("{s}:{d} ({s})", .{ loc.file, loc.line, loc.fn_name });
                        try writer.print(" | {d:<10} | {d:<10}\n", .{ g.bytes, g.count });
                    } else {
                        try writer.print("0x{x:<38} | {d:<10} | {d:<10}\n", .{ g.ret_addr, g.bytes, g.count });
                    }
                    count += 1;
                }
            }
        } else {
            // JSON Output
            try writer.print("{{\n", .{});
            try writer.print("  \"total_allocated\": {d},\n", .{self.total_allocated});
            try writer.print("  \"total_freed\": {d},\n", .{self.total_freed});
            try writer.print("  \"peak_allocated\": {d},\n", .{self.peak_allocated});
            try writer.print("  \"leaked_bytes\": {d},\n", .{leaked_bytes});

            if (leaked_count > 0) {
                try writer.print("  \"leaked_count\": {d},\n", .{leaked_count});
                try writer.print("  \"leaks\": [\n", .{});

                var list = self.getLeakGroups();
                defer list.deinit();

                var count: usize = 0;
                for (list.items) |g| {
                    if (count >= options.top) break;
                    if (count > 0) try writer.print(",\n", .{});

                    try writer.print("    {{\n", .{});
                    if (g.src_loc) |loc| {
                        try writer.print("      \"file\": \"{s}\",\n", .{loc.file});
                        try writer.print("      \"line\": {d},\n", .{loc.line});
                        try writer.print("      \"function\": \"{s}\",\n", .{loc.fn_name});
                    } else {
                        try writer.print("      \"address\": {d},\n", .{g.ret_addr});
                    }
                    try writer.print("      \"bytes\": {d},\n", .{g.bytes});
                    try writer.print("      \"count\": {d}\n", .{g.count});
                    try writer.print("    }}", .{});

                    count += 1;
                }
                try writer.print("\n  ]\n", .{});
            } else {
                try writer.print("  \"leaked_count\": {d}\n", .{leaked_count});
            }
            try writer.print("}}\n", .{});
        }
    }

    pub fn deinitAndReport(self: *HeapWatchAllocator, options: ReportOptions) void {
        const stdout = std.io.getStdOut().writer();
        self.writeReport(stdout, options) catch {};
        self.deinit();
    }

    pub fn deinit(self: *HeapWatchAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.allocations.deinit();
    }
};

test "HeapWatchAllocator basic usage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var hw = HeapWatchAllocator.init(gpa.allocator(), .{});
    defer hw.deinit();

    const allocator = hw.allocator();

    const ptr = try allocator.alloc(u8, 100);
    try std.testing.expectEqual(100, hw.total_allocated);
    try std.testing.expectEqual(100, hw.current_allocated);
    try std.testing.expectEqual(1, hw.alloc_count);

    allocator.free(ptr);
    try std.testing.expectEqual(100, hw.total_freed);
    try std.testing.expectEqual(0, hw.current_allocated);
    try std.testing.expectEqual(1, hw.free_count);
}

test "HeapWatchAllocator leak detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var hw = HeapWatchAllocator.init(arena.allocator(), .{});

    const allocator = hw.allocator();
    _ = try allocator.alloc(u8, 50);

    try std.testing.expectEqual(50, hw.current_allocated);
    try std.testing.expectEqual(1, hw.allocations.count());

    hw.deinitAndReport(.{});
}

test "HeapWatchAllocator source capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var hw = HeapWatchAllocator.init(arena.allocator(), .{ .capture = .source });

    _ = try hw.allocWithSrc(u8, 20, @src());

    try std.testing.expectEqual(20, hw.current_allocated);

    // Check if source location was captured
    var iter = hw.allocations.iterator();
    const entry = iter.next().?;
    try std.testing.expect(entry.value_ptr.src_loc != null);

    hw.deinitAndReport(.{});
}

test "HeapWatchAllocator resize tracking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var hw = HeapWatchAllocator.init(arena.allocator(), .{});
    const alloc = hw.allocator();

    var ptr = try alloc.alloc(u8, 10);
    var current_len: usize = 10;
    try std.testing.expectEqual(10, hw.current_allocated);

    // Grow
    if (alloc.resize(ptr, 20)) {
        ptr = ptr.ptr[0..20];
        current_len = 20;
        try std.testing.expectEqual(20, hw.current_allocated);
    }

    // Shrink
    if (alloc.resize(ptr, 5)) {
        const diff = current_len - 5;
        ptr = ptr.ptr[0..5];
        try std.testing.expectEqual(5, hw.current_allocated);
        try std.testing.expectEqual(diff, hw.total_freed);
    }

    hw.deinitAndReport(.{});
}

test "HeapWatchAllocator fuzz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var hw = HeapWatchAllocator.init(arena.allocator(), .{});
    const alloc = hw.allocator();

    var prng = std.rand.DefaultPrng.init(1234);
    const random = prng.random();

    var ptrs = std.ArrayList([]u8).init(std.testing.allocator);
    defer ptrs.deinit();

    for (0..1000) |_| {
        const action = random.intRangeAtMost(u8, 0, 2);
        if (action == 0 or ptrs.items.len == 0) {
            // Alloc
            const size = random.intRangeAtMost(usize, 1, 1024);
            const ptr = try alloc.alloc(u8, size);
            try ptrs.append(ptr);
        } else if (action == 1) {
            // Free
            const idx = random.intRangeAtMost(usize, 0, ptrs.items.len - 1);
            const ptr = ptrs.swapRemove(idx);
            alloc.free(ptr);
        } else {
            // Resize
            const idx = random.intRangeAtMost(usize, 0, ptrs.items.len - 1);
            var ptr = ptrs.items[idx];
            const new_size = random.intRangeAtMost(usize, 1, 1024);
            if (alloc.resize(ptr, new_size)) {
                ptrs.items[idx] = ptr.ptr[0..new_size];
            }
        }
    }

    // Sanity check
    try std.testing.expectEqual(hw.total_allocated - hw.total_freed, hw.current_allocated);

    hw.deinitAndReport(.{});
}
