const std = @import("std");
const heapwatch = @import("heapwatch");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 2) {
        usage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "demo")) {
        try doDemo(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "report")) {
        try doReport(allocator, args[2..]);
    } else {
        usage();
    }
}

fn usage() void {
    std.debug.print(
        \\Usage: heapwatch <command> [args...]
        \\
        \\Commands:
        \\  demo [--leak] [--churn N]  Run demo with intentional leaks and churn
        \\  report <file>              Read JSON report and print table
        \\
        \\
    , .{});
}

fn doDemo(allocator: std.mem.Allocator, args: [][]u8) !void {
    _ = allocator;
    var leak = false;
    var churn: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--leak")) {
            leak = true;
        } else if (std.mem.eql(u8, arg, "--churn")) {
            if (i + 1 < args.len) {
                churn = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        }
    }

    std.debug.print("Running demo... (leak={?}, churn={d})\n", .{ leak, churn });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var hw = heapwatch.HeapWatchAllocator.init(gpa.allocator(), .{ .capture = .source });
    defer {
        // Generate report at end
        const stdout = std.io.getStdOut().writer();
        hw.writeReport(stdout, .{ .format = .human }) catch {};

        // Also write JSON
        if (std.fs.cwd().createFile("heapwatch_report.json", .{})) |file| {
            defer file.close();
            hw.writeReport(file.writer(), .{ .format = .json }) catch {};
            std.debug.print("Wrote JSON report to heapwatch_report.json\n", .{});
        } else |err| {
            std.debug.print("Failed to write JSON report: {}\n", .{err});
        }

        hw.deinit();
    }

    const hw_alloc = hw.allocator();

    // Churn
    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();

    for (0..churn) |_| {
        const size = random.intRangeAtMost(usize, 16, 1024);
        // Use normal alloc for churn (might not have source info if not using helper)
        // But we want to test helper too.
        // If we use hw_alloc.alloc, we get return address (light mode).
        // Since we configured .capture = .source, it will default to light if source not provided?
        // My implementation: if .source configured, allocWithSrc updates source.
        // Alloc just records ret_addr.
        // Reporting uses src if available, else ret_addr.
        // So this is fine.
        const ptr = try hw_alloc.alloc(u8, size);
        hw_alloc.free(ptr);
    }

    // Leak
    if (leak) {
        _ = try hw.allocWithSrc(u8, 128, @src()); // Leak 1
        _ = try hw.allocWithSrc(u8, 256, @src()); // Leak 2

        // Grouping test: multiple leaks at same line
        for (0..5) |_| {
            _ = try hw.allocWithSrc(u8, 64, @src());
        }
    }
}

fn doReport(allocator: std.mem.Allocator, args: [][]u8) !void {
    if (args.len < 1) {
        std.debug.print("Error: Missing report file path\n", .{});
        return;
    }
    const path = args[0];
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // We reuse the library reporting logic?
    // No, library reporting logic iterates the HashMap.
    // The CLI report command reads a JSON file and formats it.
    // I need to PARSE the JSON.
    // Since I don't want external dependencies, I'll use std.json.

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(content);

    // Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\n=== HeapWatch Report (from JSON) ===\n", .{});

    if (root.object.get("total_allocated")) |val| try stdout.print("Total Allocated: {d} bytes\n", .{val.integer});
    if (root.object.get("total_freed")) |val| try stdout.print("Total Freed:     {d} bytes\n", .{val.integer});
    if (root.object.get("peak_allocated")) |val| try stdout.print("Peak Allocated:  {d} bytes\n", .{val.integer});
    if (root.object.get("leaked_bytes")) |val| try stdout.print("Leaked Bytes:    {d} bytes\n", .{val.integer});
    if (root.object.get("leaked_count")) |val| try stdout.print("Leaked Count:    {d} allocs\n", .{val.integer});

    // TODO: if I add leak groups to JSON, iterate them here.
}
