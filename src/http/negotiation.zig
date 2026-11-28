//! Content negotiation: `Accept` against `produces` (RFC 9110 §12.5.1) and `Content-Type`
//! against `consumes`.

const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;
const http_header = @import("header.zig");
const ValueIterator = @import("fields.zig").ValueIterator;

/// Thousandths: "0.5" is 500, "1" is 1000.
const Quality = u16;

const MediaRange = struct {
    type: []const u8,
    subtype: []const u8,
    q: Quality,

    /// 0 when `range` does not match `media_type`, otherwise how specific it is: `*/*` < `type/*` < `type/subtype`.
    fn specificity(range: MediaRange, media_type: MediaType) u2 {
        if (mem.eql(u8, range.type, "*")) return 1;
        if (!ascii.eqlIgnoreCase(range.type, media_type.type)) return 0;
        if (mem.eql(u8, range.subtype, "*")) return 2;
        return if (ascii.eqlIgnoreCase(range.subtype, media_type.subtype)) 3 else 0;
    }
};

const MediaType = struct {
    type: []const u8,
    subtype: []const u8,
};

fn splitMediaType(s: []const u8) ?MediaType {
    const slash = mem.indexOfScalar(u8, s, '/') orelse return null;
    const t = s[0..slash];
    const sub = s[slash + 1 ..];
    if (!http_header.isValidName(t) or !http_header.isValidName(sub)) return null;
    return .{ .type = t, .subtype = sub };
}

pub fn isConcreteMediaType(s: []const u8) bool {
    const m = splitMediaType(s) orelse return false;
    return !mem.eql(u8, m.type, "*") and !mem.eql(u8, m.subtype, "*");
}

/// Whether `s` can be listed in `consumes`: "type/subtype", "type/*" or "*/*", without parameters.
pub fn isMediaRange(s: []const u8) bool {
    const m = splitMediaType(s) orelse return false;
    return !mem.eql(u8, m.type, "*") or mem.eql(u8, m.subtype, "*");
}

/// Matches a `Content-Type` value against the ranges of `consumes` and returns its media type
/// without parameters ("application/json; charset=utf-8" -> "application/json").
pub fn matchContentType(accepted: []const []const u8, value: []const u8) error{ Malformed, Unsupported }![]const u8 {
    var parts = mem.splitScalar(u8, value, ';');
    const media = mem.trim(u8, parts.first(), " \t");
    const m = splitMediaType(media) orelse return error.Malformed;
    if (mem.eql(u8, m.type, "*") or mem.eql(u8, m.subtype, "*")) return error.Malformed;
    for (accepted) |raw| {
        const r = splitMediaType(raw) orelse continue;
        const range: MediaRange = .{ .type = r.type, .subtype = r.subtype, .q = 1000 };
        if (range.specificity(m) > 0) return media;
    }
    return error.Unsupported;
}

/// qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] )
fn parseQuality(s: []const u8) ?Quality {
    if (s.len == 0 or s.len > 5) return null;
    if (s[0] != '0' and s[0] != '1') return null;
    var q: Quality = if (s[0] == '1') 1000 else 0;
    if (s.len == 1) return q;
    if (s[1] != '.') return null;
    var scale: Quality = 100;
    for (s[2..]) |c| {
        if (!ascii.isDigit(c)) return null;
        q += (c - '0') * scale;
        scale /= 10;
    }
    return if (q > 1000) null else q;
}

/// One element of an `Accept` list; null when malformed. Parameters other than `q` are ignored.
fn parseRange(element: []const u8) ?MediaRange {
    var parts = mem.splitScalar(u8, element, ';');
    const m = splitMediaType(mem.trim(u8, parts.first(), " \t")) orelse return null;
    if (mem.eql(u8, m.type, "*") and !mem.eql(u8, m.subtype, "*")) return null;
    var q: Quality = 1000;
    while (parts.next()) |raw| {
        const param = mem.trim(u8, raw, " \t");
        const eq = mem.indexOfScalar(u8, param, '=') orelse continue;
        if (!ascii.eqlIgnoreCase(mem.trim(u8, param[0..eq], " \t"), "q")) continue;
        q = parseQuality(mem.trim(u8, param[eq + 1 ..], " \t")) orelse return null;
        break; // anything after q is an accept-ext
    }
    return .{ .type = m.type, .subtype = m.subtype, .q = q };
}

/// Iterates the media ranges of every `Accept` line, skipping malformed ones.
const RangeIterator = struct {
    lines: ValueIterator,
    elements: ?mem.SplitIterator(u8, .scalar) = null,

    fn next(it: *RangeIterator) ?MediaRange {
        while (true) {
            if (it.elements) |*elements| {
                while (elements.next()) |element| {
                    if (parseRange(element)) |range| return range;
                }
            }
            const line = it.lines.next() orelse return null;
            it.elements = mem.splitScalar(u8, line, ',');
        }
    }
};

/// The index in `offered` of the type to send, or null when the client accepts none of them (406).
/// `accept` iterates the request's `Accept` values. Without any (valid) media range the client has
/// no preference and the first offer wins; otherwise each offer gets the q of the most specific
/// range that matches it, and the highest q wins, ties going to the earlier offer.
pub fn select(offered: []const []const u8, accept: ValueIterator) ?usize {
    var any = RangeIterator{ .lines = accept };
    if (any.next() == null) return if (offered.len == 0) null else 0;

    var best: ?usize = null;
    var best_q: Quality = 0;
    for (offered, 0..) |raw, i| {
        const media_type = splitMediaType(raw) orelse continue;
        var q: Quality = 0;
        var spec: u2 = 0;
        var ranges = RangeIterator{ .lines = accept };
        while (ranges.next()) |range| {
            const s = range.specificity(media_type);
            if (s > spec) {
                spec = s;
                q = range.q;
            }
        }
        if (q > best_q) {
            best = i;
            best_q = q;
        }
    }
    return best;
}

const testing = std.testing;
const Field = @import("fields.zig").Field;

fn expectSelect(expected: ?usize, offered: []const []const u8, lines: []const []const u8) !void {
    var fields: [8]Field = undefined;
    for (lines, 0..) |line, i| fields[i] = .{ .name = "Accept", .value = line };
    const it: ValueIterator = .{ .items = fields[0..lines.len], .name = "Accept" };
    try testing.expectEqual(expected, select(offered, it));
}

const json_html: []const []const u8 = &.{ "application/json", "text/html" };

test "negotiation: no Accept picks the first offer" {
    try expectSelect(0, json_html, &.{});
    try expectSelect(0, json_html, &.{""});
    try expectSelect(0, json_html, &.{" , ,"});
    try expectSelect(null, &.{}, &.{});
}

test "negotiation: exact and wildcard matches" {
    try expectSelect(1, json_html, &.{"text/html"});
    try expectSelect(0, json_html, &.{"*/*"});
    try expectSelect(1, json_html, &.{"text/*"});
    try expectSelect(0, json_html, &.{"APPLICATION/JSON"});
    try expectSelect(null, json_html, &.{"image/png"});
}

test "negotiation: q-values decide, ties go to the server's order" {
    try expectSelect(1, json_html, &.{"application/json;q=0.5, text/html"});
    try expectSelect(0, json_html, &.{"text/html;q=0.8, application/json;q=0.9"});
    try expectSelect(0, json_html, &.{"text/html, application/json"});
    try expectSelect(1, json_html, &.{"text/html ; q=1.000 , application/json ; Q=0.999"});
}

test "negotiation: the most specific range sets the quality" {
    // text/html is refused even though */* accepts everything.
    try expectSelect(0, json_html, &.{"text/html;q=0, */*"});
    try expectSelect(null, json_html, &.{"application/*;q=0, text/*;q=0, image/png"});
    try expectSelect(1, json_html, &.{"*/*;q=0.1, text/*;q=0.5, application/json;q=0.2"});
}

test "negotiation: several Accept lines are one list" {
    try expectSelect(1, json_html, &.{ "image/png", "text/html" });
}

test "negotiation: malformed ranges are skipped" {
    try expectSelect(1, json_html, &.{"application/json;q=2, text/html"});
    try expectSelect(1, json_html, &.{"*/json, text/html"});
    try expectSelect(0, json_html, &.{"garbage"}); // nothing valid: no preference
    try expectSelect(0, json_html, &.{"application/json;charset=utf-8"});
}

test "negotiation: qvalue syntax" {
    try testing.expectEqual(@as(?Quality, 0), parseQuality("0"));
    try testing.expectEqual(@as(?Quality, 500), parseQuality("0.5"));
    try testing.expectEqual(@as(?Quality, 123), parseQuality("0.123"));
    try testing.expectEqual(@as(?Quality, 1000), parseQuality("1."));
    try testing.expectEqual(@as(?Quality, null), parseQuality("1.001"));
    try testing.expectEqual(@as(?Quality, null), parseQuality("0.1234"));
    try testing.expectEqual(@as(?Quality, null), parseQuality(".5"));
    try testing.expectEqual(@as(?Quality, null), parseQuality("2"));
}

test "negotiation: concrete media types" {
    try testing.expect(isConcreteMediaType("application/json"));
    try testing.expect(isConcreteMediaType("application/vnd.api+json"));
    try testing.expect(!isConcreteMediaType("text/*"));
    try testing.expect(!isConcreteMediaType("application/json; charset=utf-8"));
    try testing.expect(!isConcreteMediaType("json"));
    try testing.expect(!isConcreteMediaType("/json"));
}

test "negotiation: media ranges for consumes" {
    try testing.expect(isMediaRange("application/json"));
    try testing.expect(isMediaRange("image/*"));
    try testing.expect(isMediaRange("*/*"));
    try testing.expect(!isMediaRange("*/json"));
    try testing.expect(!isMediaRange("text/plain; charset=utf-8"));
    try testing.expect(!isMediaRange("text"));
}

test "negotiation: Content-Type against consumes" {
    const json: []const []const u8 = &.{"application/json"};
    try testing.expectEqualStrings("application/json", try matchContentType(json, "application/json"));
    try testing.expectEqualStrings("Application/JSON", try matchContentType(json, " Application/JSON ; charset=utf-8"));
    try testing.expectError(error.Unsupported, matchContentType(json, "text/plain"));
    try testing.expectError(error.Unsupported, matchContentType(json, "application/jsonx"));

    const images: []const []const u8 = &.{ "application/json", "image/*" };
    try testing.expectEqualStrings("image/png", try matchContentType(images, "image/png"));
    try testing.expectError(error.Unsupported, matchContentType(images, "text/png"));
    try testing.expectEqualStrings("text/csv", try matchContentType(&.{"*/*"}, "text/csv"));

    try testing.expectError(error.Malformed, matchContentType(json, ""));
    try testing.expectError(error.Malformed, matchContentType(json, "json"));
    try testing.expectError(error.Malformed, matchContentType(json, "application/"));
    try testing.expectError(error.Malformed, matchContentType(&.{"*/*"}, "image/*"));
}
