# -*- coding: utf-8 -*-
"""20b が壊して緑になった判定関数が、いまはテストで赤になるかを確認する。

計画書の規則「判定関数を足すコミットでテストも足す。テストが実際にその関数を
固定しているかは、関数の挙動を機械的に変えてテストが落ちるかで確かめる」の実行。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from harness import Harness, first_line

MAIN = "tools/check-docs/main.zig"

h = Harness("r20mut", live=(MAIN, "build.zig",
                            "tools/extract-r7rs-required/main.zig",
                            "docs/adr/0026-verify-facts-about-code-not-prose.md"))
cases = []


def case(name, apply):
    cases.append((name, apply))


# closingBacktickRun を壊す。
case("T1 closingBacktickRun always returns null", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "fn closingBacktickRun(line: []const u8, from: usize, len: usize) ?usize {\n",
        "fn closingBacktickRun(line: []const u8, from: usize, len: usize) ?usize {\n"
        "    if (line.len != 0 and from <= line.len and len != 0) return null;\n", 1)))
case("T2 closingBacktickRun closes on a longer run", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "        if (run - i == len) return i;", "        if (run - i >= len) return i;", 1)))

# fenceRun の情報文字列の規則を外す。
case("T3 the backtick info string rule removed", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "    if (ch == '`' and std.mem.indexOfScalar(u8, rest, '`') != null) return null;\n",
        "", 1)))

# referenceDefinition のマーカー剥がしとラベルの扱いを外す。
case("T4 the marker stripping disabled", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "        if (line.len != 0 and line[0] == '>') {",
        "        if (false and line.len != 0 and line[0] == '>') {", 1)))
case("T5 the escaped bracket in a label ignored", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "        if (line[i] == '\\\\') {\n            i += 1;\n            continue;\n        }\n"
        "        if (line[i] == '[') return null; // an unescaped bracket is not a label",
        "        if (line[i] == '[') return null; // an unescaped bracket is not a label", 1)))

# listContentColumn を壊す。
case("T6 listContentColumn always returns null", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "fn listContentColumn(indent: usize, trimmed: []const u8) ?usize {\n",
        "fn listContentColumn(indent: usize, trimmed: []const u8) ?usize {\n"
        "    if (trimmed.len != 0 and indent <= trimmed.len + indent) return null;\n", 1)))

# yamlKey / keyIsAllowed / identifierCount / hasTestBlock を壊す。
case("T7 yamlKey accepts any character in a key", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;",
        "        if (false and !std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return null;", 1)))
case("T8 keyIsAllowed accepts everything", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "fn keyIsAllowed(key: []const u8) bool {\n",
        "fn keyIsAllowed(key: []const u8) bool {\n    if (key.len != 0) return true;\n", 1)))
case("T9 identifierCount counts comment lines", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "        if (line.len == 0 or line[0] == ';') continue;",
        "        if (line.len == 0) continue;", 1)))
case("T10 hasTestBlock always returns true", lambda h: h.edit(
    MAIN, lambda s: s.replace(
        "fn hasTestBlock(source: [:0]const u8) bool {\n",
        "fn hasTestBlock(source: [:0]const u8) bool {\n    if (source.len >= 0) return true;\n", 1)))

code, out = h.run("test")
print("%-4s %-50s exit=%d  %s" % ("OK" if code == 0 else "BAD", "baseline", code, first_line(out)[:40]))
for name, apply in cases:
    h.reset()
    try:
        apply(h)
    except AssertionError as e:
        print("%-4s %-50s (edit skipped: %s)" % ("??", name, e))
        continue
    code, out = h.run("test")
    # 変異させたら赤になるべき。
    print("%-4s %-50s exit=%d  %s" % ("OK" if code != 0 else "BAD", name, code, first_line(out)[:52]))

h.reset()
h.drop()
