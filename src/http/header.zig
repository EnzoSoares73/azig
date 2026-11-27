const std = @import("std");
const ascii = std.ascii;

/// A header name must be a non-empty token (RFC 9110 §5.1).
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!isTokenChar(c)) return false;
    }
    return true;
}

/// A header value must not contain CR, LF or NUL (RFC 9110 §5.5). Allowing them would let
/// a value end the header line early and inject headers, or even a body, into a response.
pub fn isValidValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n' or c == 0) return false;
    }
    return true;
}

fn isTokenChar(c: u8) bool {
    return ascii.isAlphanumeric(c) or switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

const testing = std.testing;

test "header name validation" {
    try testing.expect(isValidName("Content-Type"));
    try testing.expect(isValidName("X-Custom_Header.1"));
    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName("Content-Length "));
    try testing.expect(!isValidName("Bad:Name"));
    try testing.expect(!isValidName("X-Injected\r\nSet-Cookie"));
}

test "header value validation" {
    try testing.expect(isValidValue("text/html; charset=utf-8"));
    try testing.expect(isValidValue(""));
    try testing.expect(!isValidValue("value\r\nSet-Cookie: session=evil"));
    try testing.expect(!isValidValue("value\n"));
}
