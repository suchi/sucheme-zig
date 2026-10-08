# -*- coding: utf-8 -*-
"""ADR-0026 後の CI 照合が双方向に効くかを確認する。

綴りの正規化を落としたので、表の行を隠す・綴りを崩す経路は「CI が走らせている
コマンドに対応する行が無い」という逆方向で赤になる必要がある。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from harness import Harness, first_line

ZWSP = "​"
AGENTS = "AGENTS.md"
CI = ".github/workflows/ci.yml"

DOCS_ROW = "| ドキュメントの検査 | `zig build check-docs` | 0 | 全コミット |"
DOCS_STEP = "      - run: zig build check-docs\n"
RUN_ROW = "| 実行 | `zig build run -- <引数>` | 0 | - |"
FUZZ_ROW = "| テスト(ファジング) | `zig build test --fuzz -Doptimize=ReleaseFast` | 1 | 手動と定期実行のみ |"

h = Harness("r16", live=(
    "tools/check-docs/main.zig",
    "docs/adr/0024-closed-spelling-sets.md",
    "docs/adr/0025-permission-policy-guard-in-hooks.md",
    "docs/adr/0026-verify-facts-about-code-not-prose.md",
    "docs/adr/README.md",
))
cases = []


def case(name, want_red, apply):
    cases.append((name, want_red, apply))


def drop_step(h):
    h.edit(CI, lambda s: s.replace(DOCS_STEP, "", 1))


# 順方向: 表が要求するコマンドを CI が走らせていない。
case("M1 the step is deleted", True, drop_step)

# 15巡目の修正が作った穴。記録ラベルを持たない行を字下げして打ち切らせる。
case("M2 a hidden row plus the deleted step", True, lambda h: (
    h.edit(AGENTS, lambda s: s.replace(RUN_ROW, "  " + RUN_ROW, 1)),
    drop_step(h)))

# 逆方向: CI が走らせているのに表が全コミットとして要求していない。
case("M3 a zero-width space in 全コミット", True, lambda h: h.edit(
    AGENTS, lambda s: s.replace(
        DOCS_ROW, DOCS_ROW.replace("全コミット", "全" + ZWSP + "コミット"), 1)))
case("M4 a stage cell that is not a number", True, lambda h: h.edit(
    AGENTS, lambda s: s.replace(DOCS_ROW, DOCS_ROW.replace("| 0 |", "| 0(最初から) |"), 1)))
case("M5 the row is deleted", True, lambda h: h.edit(
    AGENTS, lambda s: s.replace(DOCS_ROW + "\n", "", 1)))
case("M6 the row is marked 手動と定期実行のみ", True, lambda h: h.edit(
    AGENTS, lambda s: s.replace(
        DOCS_ROW, DOCS_ROW.replace("| 全コミット |", "| 手動と定期実行のみ |"), 1)))
case("M7 the row's stage is above the current one", True, lambda h: h.edit(
    AGENTS, lambda s: s.replace(DOCS_ROW, DOCS_ROW.replace("| 0 |", "| 1 |"), 1)))

# 別のワークフローに移しても、全コミットの行は ci.yml が走らせていなければ赤。
# 別のワークフローのキーは `allowed_workflow_keys` の中に収めている。そうしないと
# 未知のキーで赤になり、順方向が効いたのか分からなくなる。
case("M8 the step moved to another workflow", True, lambda h: (
    drop_step(h),
    h.write(".github/workflows/other.yml",
            "name: other\n\non:\n  push:\n    branches: [main]\n\n"
            "permissions:\n  contents: read\n\njobs:\n  test:\n    runs-on: ubuntu-latest\n"
            "    steps:\n      - run: zig build check-docs\n")))

# 正当な記述は緑のまま。
case("C1 the 実行 row is not in ci.yml", False, lambda h: h.edit(
    AGENTS, lambda s: s.replace(RUN_ROW, RUN_ROW.replace("| 実行 |", "| 実行(手動) |"), 1)))
case("C2 the fuzzing row is not in ci.yml", False, lambda h: h.edit(
    AGENTS, lambda s: s.replace(FUZZ_ROW, FUZZ_ROW.replace("| 1 |", "| 2 |"), 1)))
case("C3 a flag allowed after the command", False, lambda h: h.edit(
    CI, lambda s: s.replace(
        "      - run: zig build test --summary all\n",
        "      - run: zig build test\n", 1)))
case("C4 an ADR index row indented by two spaces", False, lambda h: h.edit(
    "docs/adr/README.md",
    lambda s: s.rstrip("\n") + "\n\n一覧の行の形:\n\n  | [0000](0000-template.md) | x | - | - |\n"))

code, out = h.run()
print("%-4s %-46s exit=%d  %s" % ("OK" if code == 0 else "BAD", "baseline", code, first_line(out)[:60]))
for name, want_red, apply in cases:
    h.reset()
    try:
        apply(h)
    except AssertionError as e:
        print("%-4s %-46s (edit skipped: %s)" % ("??", name, e))
        continue
    code, out = h.run()
    ok = (code != 0) == want_red
    print("%-4s %-46s exit=%d  %s" % ("OK" if ok else "BAD", name, code, first_line(out)[:80]))

h.reset()
h.drop()
