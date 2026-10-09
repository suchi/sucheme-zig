# -*- coding: utf-8 -*-
"""17巡目(17a・17b)が緑だと報告した経路が赤になるかを確認する。"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from harness import Harness, first_line

AGENTS = "AGENTS.md"
CI = ".github/workflows/ci.yml"
ADR_README = "docs/adr/README.md"
ROADMAP = "docs/roadmap.md"

DOCS_ROW = "| ドキュメントの検査 | `zig build check-docs` | 0 | 全コミット |"
DOCS_STEP = "      - run: zig build check-docs\n"
TEST_ROW = "| テスト(単体) | `zig build test` | 0 | 全コミット |"
TEST_STEP = "      - run: zig build test --summary all\n"
FENCE = "`" * 3

h = Harness("r17c", live=(
    "tools/check-docs/main.zig",
    "tools/extract-r7rs-required/main.zig",
    "build.zig",
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
))
cases = []


def case(name, want_red, apply):
    cases.append((name, want_red, apply))


# 17a 必須1: 表の行と CI の段を対で落とす。build.zig の step が第三の点になる。
case("A-K3 row and step deleted together", True, lambda h: (
    h.edit(AGENTS, lambda s: s.replace(DOCS_ROW + "\n", "", 1)),
    h.edit(CI, lambda s: s.replace(DOCS_STEP, "", 1))))
case("A-A2 stage raised and step deleted", True, lambda h: (
    h.edit(AGENTS, lambda s: s.replace(DOCS_ROW, DOCS_ROW.replace("| 0 |", "| 1 |"), 1)),
    h.edit(CI, lambda s: s.replace(DOCS_STEP, "", 1))))
case("A-A2c CI cell changed and step deleted", True, lambda h: (
    h.edit(AGENTS, lambda s: s.replace(
        DOCS_ROW, DOCS_ROW.replace("| 全コミット |", "| 手動と定期実行のみ |"), 1)),
    h.edit(CI, lambda s: s.replace(DOCS_STEP, "", 1))))
case("A-K2 row indented and step deleted", True, lambda h: (
    h.edit(AGENTS, lambda s: s.replace(DOCS_ROW, "    " + DOCS_ROW, 1)),
    h.edit(CI, lambda s: s.replace(DOCS_STEP, "", 1))))
case("A-A3 three rows and three steps dropped", True, lambda h: (
    h.edit(AGENTS, lambda s: s.replace(TEST_ROW + "\n", "", 1).replace(DOCS_ROW + "\n", "", 1)),
    h.edit(CI, lambda s: s.replace(TEST_STEP, "", 1).replace(DOCS_STEP, "", 1))))

# 17a 必須2: ワークフローの値。
case("A-A6 the on: block deleted", True, lambda h: h.edit(
    CI, lambda s: s.replace("on:\n  push:\n    branches: [main]\n  pull_request:\n", "", 1)))
case("A-A9 the matrix expands to no job", True, lambda h: h.edit(
    CI, lambda s: s.replace("os: [ubuntu-latest, windows-latest]", "os: []", 1)))
case("A-A4 pull_request removed", True, lambda h: h.edit(
    CI, lambda s: s.replace("  pull_request:\n", "", 1)))
case("A-A5 branches points nowhere", True, lambda h: h.edit(
    CI, lambda s: s.replace("branches: [main]", "branches: [no-such-branch]", 1)))
case("A-A8 runs-on names no runner", True, lambda h: h.edit(
    CI, lambda s: s.replace("runs-on: ${{ matrix.os }}", "runs-on: no-such-runner", 1)))

# 17a 必須3: 生成物を手で編集して記録を貼り替える。
case("A-C1 an identifier removed and the records repasted", True, lambda h: (
    h.edit("tests/r7rs-required/base.txt", lambda s: s.replace("dynamic-wind\n", "", 1)),
    h.edit("tools/extract-r7rs-required/SOURCE.md",
           lambda s: s.replace("| `(scheme base)` | 238 |", "| `(scheme base)` | 237 |", 1))))

# 17a 推奨1: setup-zig を別ワークフローへ移す。
case("A-D5 setup-zig moved to another workflow", True, lambda h: (
    h.edit(CI, lambda s: s.replace(
        "      - uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1\n"
        "        with:\n          version: 0.17.0\n", "", 1)),
    h.write(".github/workflows/other.yml",
            "name: other\n\non:\n  push:\n    branches: [main]\n\n"
            "permissions:\n  contents: read\n\njobs:\n  test:\n    runs-on: ubuntu-latest\n"
            "    steps:\n      - uses: mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 # v2.2.1\n"
            "        with:\n          version: 0.17.0\n")))

# 17a 推奨2: 参照形式リンク。
case("A-E7 a reference definition points nowhere", True, lambda h: h.edit(
    ROADMAP, lambda s: s.rstrip("\n") + "\n\n[参考][missing]\n\n[missing]: ./no-such-file.md\n"))

# 17b 必須5: 閉じていないフェンスでリンク検査が止まる。
case("B-5 an unclosed fence hides a dead link", True, lambda h: h.edit(
    ROADMAP, lambda s: s.rstrip("\n") + "\n\n" + FENCE + "\n\n[broken](does-not-exist-xyz.md)\n"))

# 17b 必須4: ADR 一覧を HTML コメントで包む。
case("B-4 the ADR index wrapped in a comment", True, lambda h: h.edit(
    ADR_README, lambda s: s.replace("| 番号 | タイトル |", "<!" + "--\n| 番号 | タイトル |", 1) +
    "\n--" + ">\n"))

# 正当な記述は緑のまま。
case("C1 a flag allowed after a command", False, lambda h: h.edit(
    CI, lambda s: s.replace(TEST_STEP, "      - run: zig build test\n", 1)))
case("C2 the fuzzing row stays out of ci.yml", False, lambda h: h.edit(
    AGENTS, lambda s: s.replace(
        "| テスト(ファジング) |", "| テスト(ファジング実行) |", 1)))
case("C3 a closed fence hides nothing", False, lambda h: h.edit(
    ROADMAP, lambda s: s.rstrip("\n") + "\n\n" + FENCE + "\n[broken](does-not-exist-xyz.md)\n" + FENCE + "\n"))
case("C4 a reference definition that resolves", False, lambda h: h.edit(
    ROADMAP, lambda s: s.rstrip("\n") + "\n\n[SOW][sow]\n\n[sow]: plans/0001-sow.md\n"))

code, out = h.run()
print("%-4s %-50s exit=%d  %s" % ("OK" if code == 0 else "BAD", "baseline", code, first_line(out)[:50]))
for name, want_red, apply in cases:
    h.reset()
    try:
        apply(h)
    except AssertionError as e:
        print("%-4s %-50s (edit skipped: %s)" % ("??", name, e))
        continue
    code, out = h.run()
    ok = (code != 0) == want_red
    print("%-4s %-50s exit=%d  %s" % ("OK" if ok else "BAD", name, code, first_line(out)[:70]))

h.reset()
h.drop()
