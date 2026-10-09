# -*- coding: utf-8 -*-
"""20巡目が緑だと報告した経路が赤になるかを確認する。

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
TILDE = "~"

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
]
live += ["tests/r7rs-required/%s" % p.name for p in (ROOT / "tests/r7rs-required").glob("*.txt")]

h = Harness("r20fix", live=tuple(live))
cases = []


def case(name, step, want_red, apply):
    cases.append((name, step, want_red, apply))


def para(body):
    """前に段落と空行を置く。文脈を確定させるため。"""
    return lambda s: s.rstrip("\n") + "\n\n説明の段落。\n\n" + body + "\n"


# 安い綻り: 出力の捕獲と2本目以降の run。
case("F1 the check-docs run captures its output", "check-docs", True, lambda h: h.edit(
    "build.zig", lambda s: s.replace(
        "    const check_docs_step = b.step(",
        "    _ = run_check_docs.captureStdOut(.{});\n    const check_docs_step = b.step(", 1)))
def second_write_run(h):
    h.edit("build.zig", lambda s: s.replace(
        "    const check_extract_step = b.step(",
        "    const extra = b.addRunArtifact(extractor);\n"
        '    extra.setCwd(b.path("."));\n'
        '    extra.addArg("--write");\n'
        "    const check_extract_step = b.step(", 1))
    h.edit("build.zig", lambda s: s.replace(
        "    checkStepRuns(check_extract_step, extractor, 1);",
        "    check_extract_step.dependOn(&extra.step);\n"
        "    checkStepRuns(check_extract_step, extractor, 1);", 1))


case("F2 a second run of the extractor on the step", "check-extract", True, second_write_run)

# 必須4: 1行で閉じない行内リンク。
case("M4a the closing paren on the next line", "check-docs", True, lambda h: h.edit(
    OQ, para("see [x](zz-m4a.md\n) end")))
case("M4b the destination on the next line", "check-docs", True, lambda h: h.edit(
    OQ, para("see [x](\nzz-m4b.md) end")))
case("M4c a title on the next line", "check-docs", True, lambda h: h.edit(
    OQ, para("see [x](zz-m4c.md\n\"t\") end")))

# 必須5: 先頭マーカーの集合。
case("M5a a quote marker with no space", "check-docs", True, lambda h: h.edit(
    OQ, para(">see [zza][zza]\n>\n>[zza]: zz-m5a.md")))
case("M5b a nested quote marker", "check-docs", True, lambda h: h.edit(
    OQ, para(">> see [zzb][zzb]\n>>\n>> [zzb]: zz-m5b.md")))
case("M5c an ordered list marker", "check-docs", True, lambda h: h.edit(
    OQ, para("1. see [zzc][zzc]\n1. [zzc]: zz-m5c.md")))
case("M5d a tab after the quote marker", "check-docs", True, lambda h: h.edit(
    OQ, para(">\tsee [zzd][zzd]\n>\n>\t[zzd]: zz-m5d.md")))

# 必須6: 字下げしたフェンス対。
case("M6a an indented pair of backtick fences", "check-docs", True, lambda h: h.edit(
    OQ, para("    " + BQ * 3 + "\ntext [x](zz-m6a.md) end\n    " + BQ * 3)))
case("M6b an indented pair of tilde fences", "check-docs", True, lambda h: h.edit(
    OQ, para("    " + TILDE * 3 + "\ntext [x](zz-m6b.md) end\n    " + TILDE * 3)))
case("M6c eight spaces of indentation", "check-docs", True, lambda h: h.edit(
    OQ, para("        " + BQ * 3 + "\ntext [x](zz-m6c.md) end\n        " + BQ * 3)))

# 正当な記述は緑のまま。
case("C1 a single indented fence is still reported", "check-docs", True, lambda h: h.edit(
    OQ, para("    " + BQ * 3 + "\ntext [x](zz-c1.md) end")))
case("C2 a fence pair at column zero", "check-docs", False, lambda h: h.edit(
    OQ, para(BQ * 3 + "\ntext [x](zz-c2.md) end\n" + BQ * 3)))
case("C3 a fence inside a numbered item", "check-docs", False, lambda h: h.edit(
    OQ, lambda s: s.rstrip("\n") +
    "\n\n1. 手順\n\n   " + BQ * 3 + "\n   [x](zz-c3.md)\n   " + BQ * 3 + "\n"))
case("C4 an inline link that closes on its line", "check-docs", False, lambda h: h.edit(
    OQ, para("see [SOW](../plans/0001-sow.md) end")))
case("C5 a quote definition that resolves", "check-docs", False, lambda h: h.edit(
    OQ, para("> [sow][sow]\n>\n> [sow]: ../plans/0001-sow.md")))
case("C6 an ordered definition that resolves", "check-docs", False, lambda h: h.edit(
    OQ, para("1. [sow][sow]\n1. [sow]: ../plans/0001-sow.md")))
case("C7 prose with a bracket and a colon", "check-docs", False, lambda h: h.edit(
    OQ, para("[参考] 次の節: 使い方。")))

for step in ("check-docs", "check-extract", "test"):
    code, out = h.run(step)
    print("%-4s %-48s %-14s exit=%d  %s" % (
        "OK" if code == 0 else "BAD", "baseline", step, code, first_line(out)[:34]))
for name, step, want_red, apply in cases:
    h.reset()
    try:
        apply(h)
    except AssertionError as e:
        print("%-4s %-48s (edit skipped: %s)" % ("??", name, e))
        continue
    code, out = h.run(step)
    ok = (code != 0) == want_red
    print("%-4s %-48s %-14s exit=%d  %s" % ("OK" if ok else "BAD", name, step, code, first_line(out)[:56]))

h.reset()
h.drop()
