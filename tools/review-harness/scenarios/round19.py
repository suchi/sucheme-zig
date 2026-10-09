# -*- coding: utf-8 -*-
"""19巡目が緑だと報告した経路が赤になるかを確認する。

複製の作成・リセット・検証コマンドの実行はすべて review_harness が Python の
subprocess で行う。シェルで手打ちしないこと(harness.py の冒頭を参照)。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from harness import Harness, first_line

ROOT = pathlib.Path(__file__).resolve().parents[3]
OQ = "docs/design/open-questions.md"
BQ = "`"

live = [
    "build.zig",
    "tools/check-docs/main.zig",
    "tools/extract-r7rs-required/main.zig",
    "tools/extract-r7rs-required/SOURCE.md",
    "AGENTS.md",
    ".github/workflows/ci.yml",
    "docs/adr/0024-closed-spelling-sets.md",
    "docs/adr/0025-permission-policy-guard-in-hooks.md",
    "docs/adr/0026-verify-facts-about-code-not-prose.md",
    "docs/adr/README.md",
    "docs/plans/0002-phase0-scaffolding.md",
    "docs/design/open-questions.md",
    "docs/review/stage0-findings.md",
    "docs/roadmap.md",
    "src/sucheme.zig",
]
live += ["tests/r7rs-required/%s" % p.name for p in (ROOT / "tests/r7rs-required").glob("*.txt")]

h = Harness("r19c", live=tuple(live))
cases = []


def case(name, step, want_red, apply):
    cases.append((name, step, want_red, apply))


def dead_link(tag):
    return lambda s: s.rstrip("\n") + "\n\n[x](zz-%s.md)\n" % tag


# 必須1: run の結果が尊重されること。
case("M1a check-docs run ignores its exit code", "check-docs", True, lambda h: (
    h.edit("build.zig", lambda s: s.replace(
        "    const check_docs_step = b.step(",
        "    run_check_docs.stdio = .{ .check = .empty };\n    const check_docs_step = b.step(", 1)),
    h.edit(OQ, dead_link("m1a"))))
case("M1b check-docs run may be skipped as foreign", "check-docs", True, lambda h: h.edit(
    "build.zig", lambda s: s.replace(
        "    const check_docs_step = b.step(",
        "    run_check_docs.skip_foreign_checks = true;\n    const check_docs_step = b.step(", 1)))
case("M1c the test run ignores its exit code", "test", True, lambda h: (
    h.edit("build.zig", lambda s: s.replace(
        "        test_step.dependOn(&b.addRunArtifact(unit).step);",
        "        const unit_run = b.addRunArtifact(unit);\n"
        "        unit_run.stdio = .{ .check = .empty };\n"
        "        test_step.dependOn(&unit_run.step);", 1)),
    h.edit("src/sucheme.zig", lambda s: s.rstrip("\n") +
           '\n\ntest "deliberately failing" {\n    try std.testing.expect(false);\n}\n')))

# 必須2: check-extract の引数。
case("M2 an argument turns the check into a rewrite", "check-extract", True, lambda h: (
    h.edit("build.zig", lambda s: s.replace(
        "    const check_extract_step = b.step(",
        '    run_check_extract.addArg("--write");\n    const check_extract_step = b.step(', 1)),
    h.edit("tests/r7rs-required/base.txt", lambda s: s.replace("\ncar\n", "\nzz-bogus\n", 1))))

# 必須4: コードスパンの綴り。
case("M4a an escaped backtick does not open a span", "check-docs", True, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\na \\" + BQ + " b [x](zz-m4a.md) \\" + BQ + " c\n"))
case("M4b a run of three does not pair with one", "check-docs", True, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\nsee " + BQ * 3 + " [x](zz-m4b.md) " + BQ + " end\n"))
case("M4c a run of five does not pair with one", "check-docs", True, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\nsee " + BQ * 5 + " [x](zz-m4c.md) " + BQ + " end\n"))

# 必須5: 参照形式の定義の位置とラベル。
case("M5a a definition inside a block quote", "check-docs", True, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n> see [zzbq][zzbq]\n>\n> [zzbq]: zz-m5a.md\n"))
case("M5b a definition inside a list item", "check-docs", True, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n- see [zzli][zzli]\n- [zzli]: zz-m5b.md\n"))
case("M5c an escaped bracket in the label", "check-docs", True, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n[zz\\]b]: zz-m5c.md\n"))

# 正当な記述は緑のまま。
case("C1 a closed span holding a link example", "check-docs", False, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n書き方は " + BQ + "[x](dest.md)" + BQ + " である。\n"))
case("C2 a double-backtick span holding a link", "check-docs", False, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n" + BQ * 2 + "[x](dest.md)" + BQ * 2 + " と書く。\n"))
case("C3 a run of three closed by three", "check-docs", False, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n" + BQ * 3 + "[x](dest.md)" + BQ * 3 + " と書く。\n"))
case("C4 a reference definition that resolves", "check-docs", False, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n[sow][sow]\n\n[sow]: ../plans/0001-sow.md\n"))
case("C5 a definition in a quote that resolves", "check-docs", False, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n> [sow][sow]\n>\n> [sow]: ../plans/0001-sow.md\n"))
case("C6 prose with a bracket and a colon", "check-docs", False, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") + "\n\n[参考] 次の節: 使い方。\n"))

for step in ("check-docs", "check-extract", "test"):
    code, out = h.run(step)
    print("%-4s %-48s %-14s exit=%d  %s" % (
        "OK" if code == 0 else "BAD", "baseline", step, code, first_line(out)[:36]))
for name, step, want_red, apply in cases:
    h.reset()
    try:
        apply(h)
    except AssertionError as e:
        print("%-4s %-48s (edit skipped: %s)" % ("??", name, e))
        continue
    code, out = h.run(step)
    ok = (code != 0) == want_red
    print("%-4s %-48s %-14s exit=%d  %s" % ("OK" if ok else "BAD", name, step, code, first_line(out)[:58]))

h.reset()
h.drop()
