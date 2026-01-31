# heapwatch

**Allocator-level heap telemetry for Zig: leaks, hotspots, peak heap.**

heapwatch is a zero/low-dependency Zig library and CLI that wraps any allocator to track allocations, detect leaks, and produce a compact hotspot report.

## Features

*   **Wrapper Allocator**: `HeapWatchAllocator` wraps any `std.mem.Allocator`.
*   **Leak Detection**: Reports leaks grouped by callsite (source file/line or return address).
*   **Hotspot Analysis**: Top allocation sites by bytes and count.
*   **Telemetry**: Tracks total allocated, total freed, peak memory usage.
*   **Callsite Capture**:
    *   **Light Mode**: Uses return address (low overhead).
    *   **Source Mode**: Captures file, line, and function name via `@src()` helper.
*   **Reporting**: Human-readable table (stdout) and JSON output.

## Integration

1.  Add `heapwatch` to your `build.zig` (assuming you have it as a module or submodule).

```zig
    const heapwatch_mod = b.addModule("heapwatch", .{
        .root_source_file = b.path("path/to/heapwatch/src/heapwatch.zig"),
    });
    exe.root_module.addImport("heapwatch", heapwatch_mod);
```

2.  Wrap your allocator in `main.zig`:

```zig
const std = @import("std");
const heapwatch = @import("heapwatch");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize HeapWatch
    var hw = heapwatch.HeapWatchAllocator.init(gpa.allocator(), .{ .capture = .source });
    defer hw.deinitAndReport(.{ .format = .human, .top = 20 });

    const alloc = hw.allocator();

    // Use helpers for precise source tracking
    const ptr = try hw.allocWithSrc(u8, 1024, @src());
    defer alloc.free(ptr);

    // Or use standard allocator interface (falls back to return address or "unknown")
    const ptr2 = try alloc.alloc(u8, 512);
    alloc.free(ptr2);
}
```

## CLI Tool

This repo comes with a `heapwatch` CLI tool (which includes a demo).

```bash
zig build run -- demo --leak
```

This runs a demo that intentionally leaks memory and prints a report.

To view a JSON report as a table:

```bash
zig build run -- report heapwatch_report.json
```

## Performance & Overhead

*   **Memory**: Uses `std.AutoHashMap` to track every live allocation. Overhead is roughly `sizeof(AllocationRecord)` (40-48 bytes) + HashMap overhead per allocation.
*   **CPU**: Acquires a mutex on every alloc/free/resize. Hashes source location or return address.
*   **Controls**: Use `.tracker_limit` in config to cap tracked allocations (dropping telemetry for excess events to avoid OOM in the tracker itself).

## JSON Schema

The JSON report format is flat:

```json
{
  "total_allocated": 1024,
  "total_freed": 512,
  "peak_allocated": 1024,
  "leaked_bytes": 512,
  "leaked_count": 1,
  "leaks": [
    {
      "file": "src/main.zig",
      "line": 42,
      "function": "main",
      "bytes": 512,
      "count": 1
    }
  ]
}
```
