//! In-memory history of the line editor (docs/plans/0021-stage7-8-early-parts.md, 7d).
//!
//! 記憶上の履歴への追加、上下の移動(`Browser`)、逐次検索(`Search`、Ctrl-R)を持つ。
//! ファイルへの保存は 7n である。
//!
//! 複数行の式は、閉じたときに、行を改行でつないだ1項目として記録する(`addLines`)。
//! 上下の移動と逐次検索は、複数行の項目も返す(複数行の再描画は 7m で入った)。呼び出せるかの
//! 判定は `isRecallable` の1か所で、上下の移動と逐次検索が同じものを使う。

const std = @import("std");

const Allocator = std.mem.Allocator;

/// 項目の数の上限の既定値。上限を超えたら、いちばん古いものから捨てる。
pub const default_max_items: usize = 1000;

/// Whether the editor can bring an entry back to the edit line.
///
/// Why: 編集バッファは `\r` を持てない(`Buffer` の不変条件)。`\r` を含む項目は、端末でカーソルが
/// 行頭へ戻るので、呼び出さない。改行(`\n`)は、複数行の編集(7m)で扱えるので、呼び出す。
/// 上下の移動と逐次検索が、同じこの判定を使う。
pub fn isRecallable(entry: []const u8) bool {
    return std.mem.findScalar(u8, entry, '\r') == null;
}

pub const History = struct {
    gpa: Allocator,
    /// 古いものが先。各項目は `gpa` で確保した、この履歴が持つ複製である。
    items: std.ArrayList([]u8) = .empty,
    max_items: usize,

    pub fn init(gpa: Allocator, max_items: usize) History {
        return .{ .gpa = gpa, .max_items = max_items };
    }

    pub fn deinit(self: *History) void {
        for (self.items.items) |item| self.gpa.free(item);
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn len(self: *const History) usize {
        return self.items.items.len;
    }

    /// Returns the entry at `index`, 0 being the oldest.
    pub fn get(self: *const History, index: usize) []const u8 {
        return self.items.items[index];
    }

    /// Appends one entry. Returns false when nothing was recorded.
    ///
    /// 末尾の改行(`\n`、`\r`)は落とす。空の項目(空白だけを含む)と、直前の項目と同じものは
    /// 記録しない(同じ式を続けて打っても、上下の移動で同じ行を何度も通らないようにする)。
    pub fn add(self: *History, text: []const u8) Allocator.Error!bool {
        const entry = std.mem.trimEnd(u8, text, "\r\n");
        if (std.mem.trim(u8, entry, " \t\r\n").len == 0) return false;
        if (self.max_items == 0) return false;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], entry)) return false;
        const copy = try self.gpa.dupe(u8, entry);
        errdefer self.gpa.free(copy);
        try self.items.ensureUnusedCapacity(self.gpa, 1);
        // 上限に達していれば、いちばん古いものを捨てる。確保が成功してから捨てる(失敗したときに、
        // 履歴を変えない)。
        if (self.items.items.len >= self.max_items) {
            self.gpa.free(self.items.orderedRemove(0));
        }
        self.items.appendAssumeCapacity(copy);
        return true;
    }

    /// Appends the lines of one expression as a single entry, joined by newlines.
    pub fn addLines(self: *History, lines: []const []const u8) Allocator.Error!bool {
        const joined = try std.mem.join(self.gpa, "\n", lines);
        defer self.gpa.free(joined);
        return self.add(joined);
    }
};

/// Moves up and down the history for one prompt (the Up and Down keys, Ctrl-P and Ctrl-N).
///
/// 1回のプロンプトごとに作り、プロンプトの間に `History` が変わる前に捨てる(位置は項目の
/// 番号で、`History.add` のあとは、どの項目を指すかが変わりうる)。履歴の外から上へ動いた時点の
/// 編集中の行を覚えておき、下へ動いて新しい側の端に戻ったときに、それを返す。呼び出した項目を
/// 編集してから動くと、その編集は捨てる(覚えるのは、履歴に入る前の行だけである)。
pub const Browser = struct {
    history: *const History,
    gpa: Allocator,
    /// 現在の位置。`history.len()` は、履歴の外(編集中の行)を指す。
    pos: usize,
    /// 履歴に入る前の編集中の行。履歴の外から上へ動くたびに、複製し直す。
    draft: ?[]u8 = null,
    /// `draft` が、いまの編集中の行を表しているか。履歴の外へ戻ったら false にする。
    drafted: bool = false,

    pub fn init(gpa: Allocator, history: *const History) Browser {
        return .{ .history = history, .gpa = gpa, .pos = history.len() };
    }

    pub fn deinit(self: *Browser) void {
        if (self.draft) |d| self.gpa.free(d);
        self.* = undefined;
    }

    /// Moves to the next older entry that can be recalled and returns it, or returns null when
    /// there is none (the line is left as it is). `current` is the edit line, kept as the draft the
    /// first time.
    pub fn older(self: *Browser, current: []const u8) Allocator.Error!?[]const u8 {
        var i = self.pos;
        while (i > 0) {
            i -= 1;
            if (!isRecallable(self.history.get(i))) continue;
            if (!self.drafted) {
                const copy = try self.gpa.dupe(u8, current);
                if (self.draft) |d| self.gpa.free(d);
                self.draft = copy;
                self.drafted = true;
            }
            self.pos = i;
            return self.history.get(i);
        }
        return null;
    }

    /// Moves to the next newer entry that can be recalled and returns it. Past the newest one it
    /// returns the draft and leaves the history. Returns null when it is already outside the
    /// history.
    pub fn newer(self: *Browser) ?[]const u8 {
        if (self.pos >= self.history.len()) return null;
        var i = self.pos + 1;
        while (i < self.history.len()) : (i += 1) {
            if (!isRecallable(self.history.get(i))) continue;
            self.pos = i;
            return self.history.get(i);
        }
        self.pos = self.history.len();
        // 履歴の外へ戻った。次に上へ動くときは、そのときの編集中の行を覚え直す。
        self.drafted = false;
        return self.draft orelse "";
    }
};

/// Incremental backward search (Ctrl-R).
///
/// 検索語は、バイト列の部分一致で、大文字と小文字を区別する(Scheme が区別するため)。
/// 検索語が空のときは、何にも一致しない。新しい項目から古い項目へ向かう。
/// `Browser` と同じく、1回の検索ごとに作り、検索の間に `History.add` を呼ばない
/// (位置は項目の番号で、上限での追い出しのあとは、別の項目を指す)。
pub const Search = struct {
    history: *const History,
    gpa: Allocator,
    query: std.ArrayList(u8) = .empty,
    /// 一致している項目の番号。一致が無いとき(検索語が空のときを含む)は null。
    match: ?usize = null,

    pub fn init(gpa: Allocator, history: *const History) Search {
        return .{ .history = history, .gpa = gpa };
    }

    pub fn deinit(self: *Search) void {
        self.query.deinit(self.gpa);
        self.* = undefined;
    }

    /// The query typed so far.
    pub fn text(self: *const Search) []const u8 {
        return self.query.items;
    }

    /// The matching entry, or null when nothing matches.
    pub fn current(self: *const Search) ?[]const u8 {
        const m = self.match orelse return null;
        return self.history.get(m);
    }

    /// Where the query starts in the matching entry, for the display.
    pub fn matchOffset(self: *const Search) ?usize {
        const entry = self.current() orelse return null;
        return std.mem.find(u8, entry, self.query.items);
    }

    /// Appends text to the query. The search stays on the current match when it still matches,
    /// and otherwise goes on to the next older one.
    pub fn append(self: *Search, bytes: []const u8) Allocator.Error!void {
        if (bytes.len == 0) return;
        const was_empty = self.query.items.len == 0;
        try self.query.appendSlice(self.gpa, bytes);
        // 一致が無いまま語を伸ばしても、一致は現れない(検索語が空のときの最初の語は別)。
        if (self.match == null and !was_empty) return;
        self.match = self.find(if (was_empty) self.history.len() else self.match.? + 1);
    }

    /// Removes the last character of the query, and searches again from the newest entry.
    pub fn backspace(self: *Search) void {
        const items = self.query.items;
        if (items.len == 0) return;
        var n = items.len - 1;
        // UTF-8 の続きのバイト(10xxxxxx)を、先頭のバイトまで戻す。
        while (n > 0 and items[n] & 0xC0 == 0x80) n -= 1;
        self.query.shrinkRetainingCapacity(n);
        self.match = self.find(self.history.len());
    }

    /// Goes to the next older match (Ctrl-R pressed again). Does nothing when nothing matches.
    pub fn olderMatch(self: *Search) void {
        const m = self.match orelse return;
        if (self.find(m)) |older| self.match = older;
    }

    /// Goes to the next newer match (Ctrl-S in some editors). Does nothing when there is none.
    pub fn newerMatch(self: *Search) void {
        const m = self.match orelse return;
        var i = m + 1;
        while (i < self.history.len()) : (i += 1) {
            if (self.matches(i)) {
                self.match = i;
                return;
            }
        }
    }

    fn matches(self: *const Search, index: usize) bool {
        const entry = self.history.get(index);
        return isRecallable(entry) and std.mem.find(u8, entry, self.query.items) != null;
    }

    /// The newest matching entry older than `before` (an index), or null.
    fn find(self: *const Search, before: usize) ?usize {
        if (self.query.items.len == 0) return null;
        var i = @min(before, self.history.len());
        while (i > 0) {
            i -= 1;
            if (self.matches(i)) return i;
        }
        return null;
    }
};

// ---- tests ----

const testing = std.testing;

fn filled(gpa: Allocator, entries: []const []const u8) !History {
    var h = History.init(gpa, default_max_items);
    errdefer h.deinit();
    for (entries) |e| _ = try h.add(e);
    return h;
}

test "add records entries, oldest first" {
    var h = try filled(testing.allocator, &.{ "(+ 1 2)", "(define x 3)" });
    defer h.deinit();
    try testing.expectEqual(@as(usize, 2), h.len());
    try testing.expectEqualStrings("(+ 1 2)", h.get(0));
    try testing.expectEqualStrings("(define x 3)", h.get(1));
}

test "add drops trailing newlines, and records nothing for a blank entry" {
    var h = History.init(testing.allocator, 10);
    defer h.deinit();
    try testing.expect(try h.add("(f)\r\n"));
    try testing.expectEqualStrings("(f)", h.get(0));
    try testing.expect(!try h.add(""));
    try testing.expect(!try h.add("   \t"));
    try testing.expect(!try h.add("\n"));
    try testing.expectEqual(@as(usize, 1), h.len());
}

test "add skips an entry equal to the previous one, but not an older one" {
    var h = History.init(testing.allocator, 10);
    defer h.deinit();
    try testing.expect(try h.add("a"));
    try testing.expect(!try h.add("a"));
    try testing.expect(try h.add("b"));
    try testing.expect(try h.add("a"));
    try testing.expectEqual(@as(usize, 3), h.len());
}

test "add keeps leading spaces of an entry" {
    var h = History.init(testing.allocator, 10);
    defer h.deinit();
    _ = try h.add("  (f)");
    try testing.expectEqualStrings("  (f)", h.get(0));
}

test "at the limit, the oldest entry goes first" {
    var h = History.init(testing.allocator, 3);
    defer h.deinit();
    for ([_][]const u8{ "1", "2", "3", "4" }) |e| _ = try h.add(e);
    try testing.expectEqual(@as(usize, 3), h.len());
    try testing.expectEqualStrings("2", h.get(0));
    try testing.expectEqualStrings("4", h.get(2));
}

test "a limit of 0 records nothing" {
    var h = History.init(testing.allocator, 0);
    defer h.deinit();
    try testing.expect(!try h.add("a"));
    try testing.expectEqual(@as(usize, 0), h.len());
}

test "addLines joins the lines of one expression with newlines, as one entry" {
    var h = History.init(testing.allocator, 10);
    defer h.deinit();
    try testing.expect(try h.addLines(&.{ "(define (f x)", "  (* x 2))" }));
    try testing.expectEqual(@as(usize, 1), h.len());
    try testing.expectEqualStrings("(define (f x)\n  (* x 2))", h.get(0));
    try testing.expect(isRecallable(h.get(0)));
}

test "add does not leak when the allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var h = History.init(gpa, 2);
            defer h.deinit();
            _ = try h.add("one");
            _ = try h.add("two");
            _ = try h.add("three");
            _ = try h.addLines(&.{ "a", "b" });
        }
    }.run, .{});
}

test "a failed add at the limit leaves the history as it was, whichever allocation fails" {
    // 確保の何番目で失敗させても、成功か、履歴が元のままかの、どちらかである。
    var skip: usize = 0;
    while (skip < 4) : (skip += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var h = History.init(failing.allocator(), 2);
        defer h.deinit();
        _ = try h.add("one");
        _ = try h.add("two");
        failing.fail_index = failing.alloc_index + skip;
        if (h.add("three")) |added| {
            try testing.expect(added);
            try testing.expectEqualStrings("two", h.get(0));
            try testing.expectEqualStrings("three", h.get(1));
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 2), h.len());
            try testing.expectEqualStrings("one", h.get(0));
            try testing.expectEqualStrings("two", h.get(1));
        }
    }
}

test "Browser: older walks back from the newest and keeps the line being edited" {
    var h = try filled(testing.allocator, &.{ "a", "b", "c" });
    defer h.deinit();
    var b = Browser.init(testing.allocator, &h);
    defer b.deinit();
    try testing.expectEqualStrings("c", (try b.older("draft")).?);
    try testing.expectEqualStrings("b", (try b.older("ignored")).?);
    try testing.expectEqualStrings("a", (try b.older("ignored")).?);
    try testing.expectEqual(@as(?[]const u8, null), try b.older("ignored"));
    // 下へ戻ると、途中の項目を通り、端で最初の編集中の行に戻る。
    try testing.expectEqualStrings("b", b.newer().?);
    try testing.expectEqualStrings("c", b.newer().?);
    try testing.expectEqualStrings("draft", b.newer().?);
    try testing.expectEqual(@as(?[]const u8, null), b.newer());
}

test "Browser: newer does nothing before the first older, and an empty history has nothing to bring back" {
    var h = History.init(testing.allocator, 10);
    defer h.deinit();
    var b = Browser.init(testing.allocator, &h);
    defer b.deinit();
    try testing.expectEqual(@as(?[]const u8, null), b.newer());
    try testing.expectEqual(@as(?[]const u8, null), try b.older("x"));
    try testing.expectEqual(@as(?[]const u8, null), b.newer());
}

test "Browser: an entry with a carriage return is not brought back, and the entries around it are" {
    var h = History.init(testing.allocator, 10);
    defer h.deinit();
    _ = try h.add("one");
    _ = try h.add("(display \"a\rb\")");
    _ = try h.add("three");
    var b = Browser.init(testing.allocator, &h);
    defer b.deinit();
    try testing.expectEqualStrings("three", (try b.older("")).?);
    try testing.expectEqualStrings("one", (try b.older("")).?);
    try testing.expectEqual(@as(?[]const u8, null), try b.older(""));
    try testing.expectEqualStrings("three", b.newer().?);
    try testing.expectEqualStrings("", b.newer().?);
}

test "Browser: a history of only entries with a carriage return brings nothing back, and keeps no draft" {
    var h = History.init(testing.allocator, 10);
    defer h.deinit();
    _ = try h.add("a\rb");
    var b = Browser.init(testing.allocator, &h);
    defer b.deinit();
    try testing.expectEqual(@as(?[]const u8, null), try b.older("typed"));
    try testing.expectEqual(@as(?[]const u8, null), b.newer());
}

test "Browser: the draft is the line at the first older, not at a later one" {
    var h = try filled(testing.allocator, &.{ "a", "b" });
    defer h.deinit();
    var b = Browser.init(testing.allocator, &h);
    defer b.deinit();
    _ = try b.older("first");
    _ = try b.older("second");
    _ = b.newer();
    try testing.expectEqualStrings("first", b.newer().?);
}

test "Search: finds the newest entry that contains the query, and goes on to older ones" {
    var h = try filled(testing.allocator, &.{ "(define x 1)", "(display x)", "(define y 2)", "(display y)" });
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try testing.expectEqual(@as(?[]const u8, null), s.current());
    try s.append("(d");
    try testing.expectEqualStrings("(display y)", s.current().?);
    try testing.expectEqual(@as(?usize, 0), s.matchOffset());
    s.olderMatch();
    try testing.expectEqualStrings("(define y 2)", s.current().?);
    s.olderMatch();
    try testing.expectEqualStrings("(display x)", s.current().?);
    s.olderMatch();
    try testing.expectEqualStrings("(define x 1)", s.current().?);
    // これより古いものは無いので、動かない。
    s.olderMatch();
    try testing.expectEqualStrings("(define x 1)", s.current().?);
    s.newerMatch();
    try testing.expectEqualStrings("(display x)", s.current().?);
}

test "Search: a longer query stays on the match when it still matches, and moves on when it does not" {
    var h = try filled(testing.allocator, &.{ "(define x 1)", "(display x)", "(define y 2)" });
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("(d");
    try testing.expectEqualStrings("(define y 2)", s.current().?);
    try s.append("e");
    try testing.expectEqualStrings("(define y 2)", s.current().?);
    try s.append("f");
    try s.append("ine x");
    try testing.expectEqualStrings("(define x 1)", s.current().?);
    try s.append("z");
    try testing.expectEqual(@as(?[]const u8, null), s.current());
    // 一致が無いまま語を伸ばしても、一致は現れない。
    try s.append("1");
    try testing.expectEqual(@as(?[]const u8, null), s.current());
}

test "Search: backspace searches again from the newest entry" {
    var h = try filled(testing.allocator, &.{ "(define x 1)", "(display x)", "(define y 2)" });
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("(define x");
    try testing.expectEqualStrings("(define x 1)", s.current().?);
    s.backspace();
    s.backspace();
    s.backspace();
    s.backspace();
    s.backspace();
    s.backspace();
    // 検索語は "(de" になり、最も新しい一致に戻る。
    try testing.expectEqualStrings("(de", s.text());
    try testing.expectEqualStrings("(define y 2)", s.current().?);
    // 空にすると、何にも一致しない。
    s.backspace();
    s.backspace();
    s.backspace();
    try testing.expectEqualStrings("", s.text());
    try testing.expectEqual(@as(?[]const u8, null), s.current());
    s.backspace();
    try testing.expectEqualStrings("", s.text());
}

test "Search: backspace removes a whole UTF-8 character" {
    var h = try filled(testing.allocator, &.{"(display \"あい\")"});
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("あい");
    try testing.expect(s.current() != null);
    s.backspace();
    try testing.expectEqualStrings("あ", s.text());
    try testing.expect(s.current() != null);
    s.backspace();
    try testing.expectEqualStrings("", s.text());
}

test "Search: the match is case sensitive, and an empty query matches nothing" {
    var h = try filled(testing.allocator, &.{"(Define x 1)"});
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("");
    try testing.expectEqual(@as(?[]const u8, null), s.current());
    try s.append("define");
    try testing.expectEqual(@as(?[]const u8, null), s.current());
}

test "Search: an entry with a carriage return is not a match" {
    var h = History.init(testing.allocator, 10);
    defer h.deinit();
    _ = try h.add("(f 1)");
    _ = try h.add("(define (g)\r  (f 2))");
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("(f");
    try testing.expectEqualStrings("(f 1)", s.current().?);
}

test "Search: olderMatch and newerMatch do nothing when nothing matches" {
    var h = try filled(testing.allocator, &.{"a"});
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("zzz");
    s.olderMatch();
    s.newerMatch();
    try testing.expectEqual(@as(?[]const u8, null), s.current());
}

test "Browser: the draft is kept again after coming back out of the history" {
    var h = try filled(testing.allocator, &.{ "a", "b" });
    defer h.deinit();
    var b = Browser.init(testing.allocator, &h);
    defer b.deinit();
    _ = try b.older("first");
    try testing.expectEqualStrings("first", b.newer().?);
    // 利用者が打ち直してから、もう一度上へ動く。
    _ = try b.older("second");
    try testing.expectEqualStrings("second", b.newer().?);
}

test "isRecallable accepts an entry with a newline, and refuses one with a carriage return" {
    try testing.expect(isRecallable("(f 1)"));
    try testing.expect(isRecallable("a\nb"));
    try testing.expect(!isRecallable("a\rb"));
    try testing.expect(!isRecallable("a\r\nb"));
}

test "Browser: a multi-line entry is one step, whatever its number of lines" {
    var h = try filled(testing.allocator, &.{ "(old)", "(define (f x)\n  (* x 2))", "(new)" });
    defer h.deinit();
    var b = Browser.init(testing.allocator, &h);
    defer b.deinit();
    try testing.expectEqualStrings("(new)", (try b.older("")).?);
    try testing.expectEqualStrings("(define (f x)\n  (* x 2))", (try b.older("")).?);
    try testing.expectEqualStrings("(old)", (try b.older("")).?);
    try testing.expectEqualStrings("(define (f x)\n  (* x 2))", b.newer().?);
    try testing.expectEqualStrings("(new)", b.newer().?);
}

test "Search: a multi-line entry is found, and matchOffset points into its later lines" {
    var h = try filled(testing.allocator, &.{ "(g 1)", "(define (f x)\n  (* x 2))" });
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("* x");
    try testing.expectEqualStrings("(define (f x)\n  (* x 2))", s.current().?);
    try testing.expectEqual(@as(?usize, 17), s.matchOffset());
}

test "Search: matchOffset is where the query first occurs in the entry" {
    var h = try filled(testing.allocator, &.{"(f (f 1))"});
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("(f");
    try testing.expectEqual(@as(?usize, 0), s.matchOffset());
}

test "Search: a longer query stays on the older match the search had moved to" {
    var h = try filled(testing.allocator, &.{ "ab1", "ab2" });
    defer h.deinit();
    var s = Search.init(testing.allocator, &h);
    defer s.deinit();
    try s.append("a");
    try testing.expectEqualStrings("ab2", s.current().?);
    s.olderMatch();
    try testing.expectEqualStrings("ab1", s.current().?);
    try s.append("b");
    try testing.expectEqualStrings("ab1", s.current().?);
}
