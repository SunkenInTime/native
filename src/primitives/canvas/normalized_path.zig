//! Parser for Weaver's bundle-normalized icon path dialect.
//!
//! The SDK expands the full SVG path grammar before crossing the bridge.
//! Native therefore accepts only explicit absolute M/L/C/Z commands and
//! never owns arc, shorthand, or relative-command policy.

const std = @import("std");
const geometry = @import("geometry");
const drawing = @import("drawing.zig");

const PointF = geometry.PointF;
const PathElement = drawing.PathElement;

pub const Error = error{
    InvalidNormalizedPath,
    PathElementLimit,
};

const Scanner = struct {
    source: []const u8,
    index: usize = 0,

    fn skipSeparators(self: *Scanner) void {
        while (self.index < self.source.len) : (self.index += 1) {
            const byte = self.source[self.index];
            if (!std.ascii.isWhitespace(byte) and byte != ',') break;
        }
    }

    fn number(self: *Scanner) Error!f32 {
        self.skipSeparators();
        const start = self.index;
        if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) self.index += 1;
        var digits: usize = 0;
        while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) digits += 1;
        if (self.index < self.source.len and self.source[self.index] == '.') {
            self.index += 1;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) digits += 1;
        }
        if (digits == 0) return error.InvalidNormalizedPath;
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            self.index += 1;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) self.index += 1;
            var exponent_digits: usize = 0;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) exponent_digits += 1;
            if (exponent_digits == 0) return error.InvalidNormalizedPath;
        }
        const value = std.fmt.parseFloat(f32, self.source[start..self.index]) catch return error.InvalidNormalizedPath;
        if (!std.math.isFinite(value)) return error.InvalidNormalizedPath;
        return value;
    }
};

fn point(scanner: *Scanner) Error!PointF {
    return PointF.init(try scanner.number(), try scanner.number());
}

fn decode(source: []const u8, output: ?[]PathElement) Error!usize {
    var scanner = Scanner{ .source = source };
    var count: usize = 0;
    while (true) {
        scanner.skipSeparators();
        if (scanner.index == source.len) break;
        const command = source[scanner.index];
        scanner.index += 1;
        const element: PathElement = switch (command) {
            'M' => .{ .verb = .move_to, .points = .{ try point(&scanner), PointF.zero(), PointF.zero() } },
            'L' => .{ .verb = .line_to, .points = .{ try point(&scanner), PointF.zero(), PointF.zero() } },
            'C' => .{ .verb = .cubic_to, .points = .{ try point(&scanner), try point(&scanner), try point(&scanner) } },
            'Z' => .{ .verb = .close },
            else => return error.InvalidNormalizedPath,
        };
        if (output) |elements| {
            if (count >= elements.len) return error.PathElementLimit;
            elements[count] = element;
        }
        count += 1;
    }
    if (count == 0) return error.InvalidNormalizedPath;
    return count;
}

pub fn countElements(source: []const u8) Error!usize {
    return decode(source, null);
}

pub fn parse(source: []const u8, output: []PathElement) Error![]const PathElement {
    const count = try decode(source, output);
    return output[0..count];
}

test "normalized path accepts explicit absolute M L C Z only" {
    const source = "M 1 2 L 3 4 C 5 6 7 8 9 10 Z";
    try std.testing.expectEqual(@as(usize, 4), try countElements(source));
    var elements: [4]PathElement = undefined;
    const parsed = try parse(source, &elements);
    try std.testing.expectEqual(drawing.PathVerb.move_to, parsed[0].verb);
    try std.testing.expectEqual(PointF.init(9, 10), parsed[2].points[2]);
    try std.testing.expectEqual(drawing.PathVerb.close, parsed[3].verb);
}

test "normalized path rejects relative shorthand arc quadratic and malformed input" {
    for ([_][]const u8{
        "m 1 2",
        "M 1 2 H 3",
        "M 1 2 V 3",
        "M 1 2 Q 3 4 5 6",
        "M 1 2 A 3 4 0 0 0 5 6",
        "M 1 2 L nope",
        "M 1e999 2",
        "",
    }) |source| {
        try std.testing.expectError(error.InvalidNormalizedPath, countElements(source));
    }
}

test "normalized path reports caller capacity without truncating" {
    var elements: [1]PathElement = undefined;
    try std.testing.expectError(error.PathElementLimit, parse("M 0 0 L 1 1", &elements));
}
