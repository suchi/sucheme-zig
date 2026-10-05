//! Extracts the identifiers exported by each standard library from R7RS
//! Appendix A and writes them to tests/r7rs-required/<library>.txt.
//!
//! Run with `zig run tools/extract-r7rs-required/main.zig`. The input HTML is
//! committed (see SOURCE.md); nothing is fetched at build time, so the build
//! stays reproducible and offline (ADR-0013).
//!
//! This is extracted rather than typed out because the design phase produced
//! one fabricated spec quote and one non-existent procedure name when writing
//! from memory. See docs/review/adversarial-review-baseline.md.
//!
//! How Appendix A is shaped: each library's prose names it as
//! `(scheme X)</span>`, which marks the start of that library's section. The
//! exported identifiers appear as monospace spans whose text begins with a
//! non-breaking space. Inline code in the prose uses the same span but with no
//! leading non-breaking space, which is what separates the two.

const std = @import("std");

const html_path = "tools/extract-r7rs-required/appendix-a.html";
const out_dir_path = "tests/r7rs-required";
const source_url = "https://standards.scheme.org/corrected-r7rs/r7rs-Z-H-10.html";
const retrieved_on = "2026-10-06";

const lib_marker = "(scheme ";
const id_open = "<span style=\"font-family: monospace\">&#xa0;";

/// Auxiliary syntax that (scheme base) must export. If the parse drifts, these
/// are the first entries to disappear, and docs/design/frontend.md bases the
/// denotation kinds on their existence.
const base_must_have = [_][]const u8{ "...", "=>", "_", "else", "unquote", "unquote-splicing" };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.Writer.init(.stdout(), io, &buf);
    const out = &stdout.interface;

    const html = cwd.readFileAlloc(io, html_path, gpa, .unlimited) catch |err| {
        try out.print("cannot read {s}: {t}\n", .{ html_path, err });
        try out.print("run this from the repository root\n", .{});
        try out.flush();
        std.process.exit(1);
    };

    var names: std.ArrayList([]const u8) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, html, scan, lib_marker)) |at| {
        const after = at + lib_marker.len;
        const close = std.mem.indexOfScalarPos(u8, html, after, ')') orelse break;
        const tail = "</span>";
        if (std.mem.startsWith(u8, html[close + 1 ..], tail)) {
            const name = html[after..close];
            // The output file name comes from parsed HTML, which is external
            // input: a crafted name would otherwise write outside the output
            // directory. Reject anything that is not a plain library name.
            if (!isPlainLibraryName(name)) {
                try out.print("library name {s} is not a plain name\n", .{name});
                try out.flush();
                std.process.exit(1);
            }
            try names.append(gpa, name);
            try starts.append(gpa, at);
        }
        scan = after;
    }

    if (names.items.len != 16) {
        try out.print("expected 16 libraries, found {d}\n", .{names.items.len});
        try out.flush();
        std.process.exit(1);
    }

    var dir = try cwd.createDirPathOpen(io, out_dir_path, .{});
    defer dir.close(io);

    var total: usize = 0;
    for (names.items, 0..) |name, i| {
        const from = starts.items[i];
        const to = if (i + 1 < starts.items.len) starts.items[i + 1] else html.len;

        var ids: std.ArrayList([]const u8) = .empty;
        var pos = from;
        while (std.mem.indexOfPos(u8, html, pos, id_open)) |at| {
            if (at >= to) break;
            const body_start = at + id_open.len;
            const body_end = std.mem.indexOfScalarPos(u8, html, body_start, '<') orelse break;
            pos = body_end;
            const text = try decode(gpa, html[body_start..body_end]);
            if (text.len != 0) try ids.append(gpa, text);
        }

        for (ids.items) |id| {
            if (std.mem.indexOfAny(u8, id, " \t\r\n") != null) {
                try out.print("{s}: identifier {s} contains whitespace\n", .{ name, id });
                try out.flush();
                std.process.exit(1);
            }
        }

        if (std.mem.eql(u8, name, "base")) {
            for (base_must_have) |want| {
                var found = false;
                for (ids.items) |id| if (std.mem.eql(u8, id, want)) {
                    found = true;
                };
                if (!found) {
                    try out.print("(scheme base) is missing the auxiliary syntax {s}\n", .{want});
                    try out.flush();
                    std.process.exit(1);
                }
            }
        }

        const file_name = try std.fmt.allocPrint(gpa, "{s}.txt", .{name});
        var file = try dir.createFile(io, file_name, .{});
        defer file.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        const w = &fw.interface;
        try w.print("; (scheme {s}) の必須識別子。R7RS 付録A から抽出した。\n", .{name});
        try w.print("; 出典: {s}\n", .{source_url});
        try w.print("; 取得日: {s}\n", .{retrieved_on});
        try w.print("; 抽出: zig run tools/extract-r7rs-required/main.zig\n", .{});
        try w.print("; 手で編集しない。R7RS の版が上がったら再抽出する。\n", .{});
        for (ids.items) |id| try w.print("{s}\n", .{id});
        try w.flush();

        total += ids.items.len;
        try out.print("{s: <18}{d: >4}\n", .{ name, ids.items.len });
    }

    try out.print("\n{d} libraries, {d} identifiers\n", .{ names.items.len, total });
    try out.flush();
}

/// Resolves the character references Appendix A uses. The page writes `<` and
/// `>` as the numeric references `&#x3c;` and `&#x3e;`, so a decoder that only
/// knows the named forms silently drops `=>` and `char<=?`.
///
/// U+200B is dropped: tex2page inserts zero-width spaces after `?` and `<`, and
/// keeping them would stop `binary-port?` and `char<?` from ever matching a
/// library's export list. U+00A0 becomes a plain space so the whitespace check
/// below can reject it.
fn decode(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var acc: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try acc.append(gpa, raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
            try acc.append(gpa, raw[i]);
            i += 1;
            continue;
        };
        const entity = raw[i + 1 .. semi];
        i = semi + 1;
        if (codePointOf(entity)) |cp| {
            if (cp == 0x200b) continue;
            const scalar = if (cp == 0xa0) ' ' else cp;
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(scalar, &utf8) catch {
                try acc.append(gpa, '?');
                continue;
            };
            try acc.appendSlice(gpa, utf8[0..n]);
        } else {
            // Unknown reference: keep it verbatim so the whitespace and
            // auxiliary-syntax checks notice rather than silently accepting it.
            try acc.append(gpa, '&');
            try acc.appendSlice(gpa, entity);
            try acc.append(gpa, ';');
        }
    }
    return std.mem.trim(u8, acc.items, &std.ascii.whitespace);
}

/// Library names become output file names, so only lowercase letters, digits
/// and internal hyphens are allowed. This keeps a crafted or corrupted input
/// from building a path that escapes the output directory.
fn isPlainLibraryName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Maps an entity body (the text between `&` and `;`) to a code point.
fn codePointOf(entity: []const u8) ?u21 {
    if (entity.len == 0) return null;
    if (entity[0] == '#') {
        const digits = entity[1..];
        if (digits.len == 0) return null;
        if (digits[0] == 'x' or digits[0] == 'X')
            return std.fmt.parseInt(u21, digits[1..], 16) catch null;
        return std.fmt.parseInt(u21, digits, 10) catch null;
    }
    const named = [_]struct { name: []const u8, cp: u21 }{
        .{ .name = "amp", .cp = '&' },
        .{ .name = "lt", .cp = '<' },
        .{ .name = "gt", .cp = '>' },
        .{ .name = "quot", .cp = '"' },
        .{ .name = "nbsp", .cp = 0xa0 },
    };
    for (named) |n| if (std.mem.eql(u8, entity, n.name)) return n.cp;
    return null;
}
