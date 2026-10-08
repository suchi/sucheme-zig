//! Extracts the identifiers exported by each standard library from R7RS
//! Appendix A and writes them to tests/r7rs-required/<library>.txt.
//!
//! Comparing is what it does by default: each file is read and checked against
//! what this program extracts, and a difference exits non-zero. `zig build
//! check-extract` runs that. Writing takes `--write`, as in `zig run
//! tools/extract-r7rs-required/main.zig -- --write`.
//!
//! Comparing is the default because the other way round left a one-line hole:
//! deleting the `--check` argument from build.zig turned the check into a
//! rewrite, so the comparison could never fail. Dropping an argument now leaves
//! it comparing. The input HTML is committed (see SOURCE.md); nothing is fetched
//! at build time, so the build stays reproducible and offline (ADR-0013).
//!
//! Without this comparison, the only thing holding the generated lists to the
//! input was a SHA-256 pasted into SOURCE.md by hand, so editing a list and
//! pasting the new hash left every verification command green with an
//! identifier silently gone from the conformance denominator.
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

/// The number of standard libraries R7RS appendix A defines. A mismatch means
/// the parse drifted, so it is checked rather than merely reported. Update it
/// together with the input when a new R7RS revision changes the set; SOURCE.md
/// names this constant in its re-extraction procedure.
const expected_library_count = 16;

/// Closes the block that holds the export lists. Used as the upper bound of the
/// last library's span, which has no following library marker to stop at.
///
/// The document opens with the same marker, and the bound is searched from the
/// last library's start, so the trailing one is the one found. If the marker
/// ever disappears the bound falls back to the end of the document, which is
/// where it was before; the per-library checks are what then catch a footer
/// span being read as an identifier.
const list_end = "<div class=navigation>";

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
    var stdout = std.Io.File.Writer.initStreaming(.stdout(), io, &buf);
    const out = &stdout.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    var check_only = true;
    for (argv[1..]) |arg| {
        // `--check` is accepted and means the default, so a caller that passes
        // it keeps working.
        if (std.mem.eql(u8, arg, "--check")) continue;
        if (std.mem.eql(u8, arg, "--write")) {
            check_only = false;
            continue;
        }
        // Reported rather than ignored: a misspelled flag would otherwise leave
        // the caller believing it had asked for something it did not get.
        try out.print("unknown argument {s}\n", .{arg});
        try out.print("usage: extract-r7rs-required [--check | --write]\n", .{});
        try out.flush();
        std.process.exit(2);
    }

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

    if (names.items.len != expected_library_count) {
        try out.print("expected {d} libraries, found {d}\n", .{ expected_library_count, names.items.len });
        try out.flush();
        std.process.exit(1);
    }

    var dir = try cwd.createDirPathOpen(io, out_dir_path, .{});
    defer dir.close(io);

    var total: usize = 0;
    var stale = false;
    for (names.items, 0..) |name, i| {
        const from = starts.items[i];
        // The last library's span is bounded like the others. Letting it run to
        // the end of the document made it asymmetric: any monospace span that
        // tex2page emits in the trailing navigation or footer would be read as
        // one of its identifiers, and neither the library count nor the
        // auxiliary-syntax check would notice.
        const to = if (i + 1 < starts.items.len)
            starts.items[i + 1]
        else
            std.mem.indexOfPos(u8, html, from, list_end) orelse html.len;

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

        // A library with no identifiers is the failure that matters most and
        // the one nothing was watching. If R7RS changes the markup of one
        // export list, this program still reports 16 libraries and succeeds,
        // and the file holds only its header comments. The conformance matrix
        // takes these files as its denominator, so that library would read as
        // fully conformant with nothing implemented.
        if (ids.items.len == 0) {
            try out.print("(scheme {s}) yielded no identifier; the markup of its export list changed\n", .{name});
            try out.flush();
            std.process.exit(1);
        }

        // A duplicate means one span was read twice, or two spans decoded to
        // the same name. Either way the count is wrong, and a count is what the
        // provenance document records.
        for (ids.items, 0..) |id, a| {
            for (ids.items[a + 1 ..]) |other| {
                if (!std.mem.eql(u8, id, other)) continue;
                try out.print("(scheme {s}) lists {s} twice\n", .{ name, id });
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
        // Built in memory first, so the same bytes can be written or compared.
        // Writing and then hashing would have compared the file with itself.
        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(gpa, try std.fmt.allocPrint(
            gpa,
            "; (scheme {s}) の必須識別子。R7RS 付録A から抽出した。\n" ++
                "; 出典: {s}\n" ++
                "; 取得日と許諾: tools/extract-r7rs-required/SOURCE.md\n" ++
                "; 抽出: zig run tools/extract-r7rs-required/main.zig -- --write\n" ++
                "; 手で編集しない。R7RS の版が上がったら再抽出する。\n",
            .{ name, source_url },
        ));
        for (ids.items) |id| {
            try content.appendSlice(gpa, id);
            try content.append(gpa, '\n');
        }

        if (check_only) {
            if (dir.readFileAlloc(io, file_name, gpa, .unlimited)) |existing| {
                if (!std.mem.eql(u8, existing, content.items)) {
                    try out.print("{s}/{s} is not what this program extracts\n", .{ out_dir_path, file_name });
                    stale = true;
                }
            } else |err| {
                try out.print("cannot read {s}/{s}: {t}\n", .{ out_dir_path, file_name, err });
                stale = true;
            }
        } else {
            var file = try dir.createFile(io, file_name, .{});
            defer file.close(io);
            var wbuf: [4096]u8 = undefined;
            var fw = file.writer(io, &wbuf);
            try fw.interface.writeAll(content.items);
            try fw.interface.flush();
        }

        total += ids.items.len;
        try out.print("{s: <18}{d: >4}\n", .{ name, ids.items.len });
    }

    try out.print("\n{d} libraries, {d} identifiers\n", .{ names.items.len, total });
    if (stale) {
        try out.print(
            "\n{s} is not what {s} extracts. Re-run `zig run tools/extract-r7rs-required/main.zig -- --write` and commit the result.\n",
            .{ out_dir_path, html_path },
        );
        try out.flush();
        std.process.exit(1);
    }
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
/// The caller owns the result. Returning a trimmed slice into the accumulator
/// would hand back a pointer the caller cannot free.
fn decode(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
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
    return gpa.dupe(u8, std.mem.trim(u8, acc.items, &std.ascii.whitespace));
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
// ---------------------------------------------------------------------------
// Tests
//
// Appendix A's markup has two traps that silently corrupt identifiers, and the
// output file name comes from parsed HTML. These cover both.
// ---------------------------------------------------------------------------

test "decode resolves the numeric references appendix A actually uses" {
    const gpa = std.testing.allocator;
    // The page writes < and > as &#x3c; and &#x3e;, not the named forms. A
    // decoder that only knew the named forms dropped => and char<=? entirely.
    const arrow = try decode(gpa, "=&#x3e;");
    defer gpa.free(arrow);
    try std.testing.expectEqualStrings("=>", arrow);

    const le = try decode(gpa, "char&#x3c;=?");
    defer gpa.free(le);
    try std.testing.expectEqualStrings("char<=?", le);
}

test "decode drops the zero-width spaces tex2page inserts" {
    const gpa = std.testing.allocator;
    // Keeping U+200B would stop binary-port? from ever matching an export
    // list, so it would read as unimplemented forever.
    const got = try decode(gpa, "binary-port?&#x200b; &#x200b;");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("binary-port?", got);
}

test "decode keeps an unknown reference verbatim" {
    const gpa = std.testing.allocator;
    // Silently dropping it would let a parse change pass unnoticed; keeping it
    // makes the whitespace and auxiliary-syntax checks notice.
    const got = try decode(gpa, "a&weird;b");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a&weird;b", got);
}

test "codePointOf handles hex, decimal and the named forms" {
    try std.testing.expectEqual(@as(?u21, '<'), codePointOf("#x3c"));
    try std.testing.expectEqual(@as(?u21, '<'), codePointOf("#X3C"));
    try std.testing.expectEqual(@as(?u21, 60), codePointOf("#60"));
    try std.testing.expectEqual(@as(?u21, '&'), codePointOf("amp"));
    try std.testing.expectEqual(@as(?u21, 0xa0), codePointOf("nbsp"));
    try std.testing.expectEqual(@as(?u21, null), codePointOf("weird"));
    try std.testing.expectEqual(@as(?u21, null), codePointOf(""));
}

test "isPlainLibraryName rejects anything that could escape the output directory" {
    try std.testing.expect(isPlainLibraryName("base"));
    try std.testing.expect(isPlainLibraryName("case-lambda"));
    try std.testing.expect(isPlainLibraryName("r5rs"));
    // The name becomes a file name, and it comes from parsed HTML.
    try std.testing.expect(!isPlainLibraryName("../etc"));
    try std.testing.expect(!isPlainLibraryName("CHAR"));
    try std.testing.expect(!isPlainLibraryName(""));
    try std.testing.expect(!isPlainLibraryName("-base"));
    try std.testing.expect(!isPlainLibraryName("base-"));
    try std.testing.expect(!isPlainLibraryName("a/b"));
    try std.testing.expect(!isPlainLibraryName("a.b"));
}
