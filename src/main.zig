//! Main CLI entrypoint for ABI Framework
//!
//! Provides command-line interface to access framework functionality.

const std = @import("std");
// Import the ABI module directly when building this file without a custom build script.
// Using the file name ensures the import works even when the project build does not
// provide a named module.
const abi = @import("abi.zig");
// Shared I/O backend helper (Zig 0.16)
// Note: This intentionally references ABI's shared module so `zig run src/main.zig`
// works without requiring the build system to define an "io" package/module.
const IoBackend = abi.services.shared.io.IoBackend;

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Skip program name
    const command = if (args.len > 1) args[1] else {
        printHelp();
        return;
    };

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        std.debug.print("ABI Framework v{s}\n", .{abi.version()});
        return;
    }

    if (std.mem.eql(u8, command, "info") or std.mem.eql(u8, command, "system-info")) {
        try printFrameworkInfo(allocator);
        return;
    }

pub const Error = error{
    EmptyText,
    BlacklistedWord,
    TextTooLong,
    InvalidValues,
    ProcessingFailed,
};

pub const Request = struct {
    text: []const u8,
    values: []const usize,

    pub fn validate(self: Request) Error!void {
        if (self.text.len == 0) return Error.EmptyText;
        if (self.values.len == 0) return Error.InvalidValues;
        _ = try Abbey.checkCompliance(self.text);
    }
};

pub const Response = struct {
    result: usize,
    message: []const u8,
};

pub const ComplianceError = error{
    EmptyText,
    BlacklistedWord,
    TextTooLong,
};

/// Abbey persona: ensures simple ethical compliance
pub const Abbey = struct {
    const MAX_TEXT_LENGTH = 1000;
    const BLACKLISTED_WORDS = [_][]const u8{ "bad", "evil", "hate" };

    pub fn isCompliant(text: []const u8) bool {
        return checkCompliance(text) catch return false;
    }

    std.debug.print("Framework initialized successfully\n", .{});

    if (abi.features.database.isEnabled()) {
        std.debug.print("Database: Available\n", .{});
    } else {
        std.debug.print("Database: Not available (enable with -Denable-database=true)\n", .{});
    }

    if (abi.features.gpu.moduleEnabled()) {
        std.debug.print("GPU: Available\n", .{});
    } else {
        std.debug.print("GPU: Not available (enable with -Denable-gpu=true)\n", .{});
    }

    if (abi.features.ai.isEnabled()) {
        std.debug.print("AI: Available\n", .{});
    } else {
        std.debug.print("AI: Not available (enable with -Denable-ai=true)\n", .{});
    }

    if (abi.features.web.isEnabled()) {
        std.debug.print("Web: Available\n", .{});
    } else {
        std.debug.print("Web: Not available (enable with -Denable-web=true)\n", .{});
    }

    if (abi.features.network.isEnabled()) {
        std.debug.print("Network: Available\n", .{});
    } else {
        std.debug.print("Network: Not available (enable with -Denable-network=true)\n", .{});
    }
}

test "Abi orchestrates personas" {
    const req = Request{ .text = "ok", .values = &[_]usize{ 1, 2 } };
    const res = try Abi.process(req);
    try std.testing.expectEqual(@as(usize, 3), res.result);
    try std.testing.expectEqualStrings("Computation successful", res.message);
}
