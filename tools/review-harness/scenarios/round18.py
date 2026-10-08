# -*- coding: utf-8 -*-
"""18巡目が緑だと報告した経路が赤になるかを確認する。"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from harness import Harness, first_line

ROOT = pathlib.Path(__file__).resolve().parents[3]
CI = ".github/workflows/ci.yml"
README = "README.md"
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
]
live += ["tests/r7rs-required/%s" % p.name for p in (ROOT / "tests/r7rs-required").glob("*.txt")]

h = Harness("r18c", live=tuple(live))
cases = []


def case(name, step, want_red, apply):
    cases.append((name, step, want_red, apply))


# H1: 検査の step が自分の run step を実行していること。
case("H1a check-docs step emptied", "check-docs", True, lambda h: h.edit(
    "build.zig", lambda s: s.replace("    check_docs_step.dependOn(&run_check_docs.step);\n", "", 1)))
case("H1b check-extract step emptied", "check-extract", True, lambda h: h.edit(
    "build.zig", lambda s: s.replace("    check_extract_step.dependOn(&run_check_extract.step);\n", "", 1)))

# H2: 比較が既定。
#
# 「`--check` の引数を落とす」シナリオは19巡目で対象が消えた。引数そのものを
# build.zig から削り、引数の数を configure 段で固定したので、落とす引数が無い。
# 引数を足す側は scenarios-round19.py の M2 が覆っている。
case("H2b the list edited and the records repasted", "check-extract", True, lambda h: h.edit(
    "tests/r7rs-required/base.txt", lambda s: s.replace("dynamic-wind\n", "", 1)))

# H3: バッククォートの偶奇でリンク検査が止まる。
case("H3a a dead link after one stray backtick", "check-docs", True, lambda h: h.edit(
    README, lambda s: s.rstrip("\n") + "\n\n" + BQ + " [x](no-such-file.md)\n"))
case("H3b a code span wrapped across two lines", "check-docs", True, lambda h: h.edit(
    README, lambda s: s.rstrip("\n") +
    "\n\n検証は " + BQ + "zig build\ncheck-docs" + BQ + " で行う([x](no-such-file.md))\n"))

# H4: 参照形式の定義の行き先が次の行。
case("H4 a definition with no destination on its line", "check-docs", True, lambda h: h.edit(
    README, lambda s: s.rstrip("\n") + "\n\n[lbl]:\n  no-such-file.md\n\nsee [lbl][lbl]\n"))

# H5: jobs: の存在。
case("H5a jobs: deleted", "check-docs", True, lambda h: h.edit(
    CI, lambda s: s.replace("jobs:\n", "", 1)))
case("H5b jobs: renamed to another allowed key", "check-docs", True, lambda h: h.edit(
    CI, lambda s: s.replace("jobs:\n", "strategy:\n", 1)))

# 正当な記述は緑のまま。
case("C1 a closed code span holding a link example", "check-docs", False, lambda h: h.edit(
    README, lambda s: s.rstrip("\n") + "\n\n書き方は " + BQ + "[x](dest.md)" + BQ + " である。\n"))
case("C2 a reference definition that resolves", "check-docs", False, lambda h: h.edit(
    README, lambda s: s.rstrip("\n") + "\n\n[sow][sow]\n\n[sow]: docs/plans/0001-sow.md\n"))
case("C3 prose with a bracket and a colon", "check-docs", False, lambda h: h.edit(
    README, lambda s: s.rstrip("\n") + "\n\n[参考] 次の節: 使い方。\n"))
case("C4 a dead link inside a fence", "check-docs", False, lambda h: h.edit(
    README, lambda s: s.rstrip("\n") + "\n\n" + BQ * 3 + "\n[x](no-such-file.md)\n" + BQ * 3 + "\n"))

for step in ("check-docs", "check-extract"):
    code, out = h.run(step)
    print("%-4s %-46s %-14s exit=%d  %s" % (
        "OK" if code == 0 else "BAD", "baseline", step, code, first_line(out)[:40]))
for name, step, want_red, apply in cases:
    h.reset()
    try:
        apply(h)
    except AssertionError as e:
        print("%-4s %-46s (edit skipped: %s)" % ("??", name, e))
        continue
    code, out = h.run(step)
    ok = (code != 0) == want_red
    print("%-4s %-46s %-14s exit=%d  %s" % ("OK" if ok else "BAD", name, step, code, first_line(out)[:62]))

h.reset()
h.drop()
