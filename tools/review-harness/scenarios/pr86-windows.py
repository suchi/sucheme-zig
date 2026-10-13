# -*- coding: utf-8 -*-
"""PR #86(Windows のテストを full.yml へ移した変更)の検査の穴と対照を確かめる。

Windows のテストを全 push の ci.yml から full.yml の windows ジョブへ移したことで、
Windows で走ることを固定していた ci.yml の `os` の値が、Windows を含まなくなった。
full.yml の windows ジョブを消す・Linux で走らせる・step を落とす編集と、
full.yml の自動の起動を外す編集が、check-docs を赤にすることを確かめる。
正当な編集(step の並べ替え、windows ジョブだけに step を足す)は緑のままである。

    python tools/review-harness/scenarios/pr86-windows.py > out.txt 2>&1
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from harness import Harness, report

FULL = ".github/workflows/full.yml"
CI = ".github/workflows/ci.yml"
TEST_STEP = "      - run: zig build test --summary all --test-timeout 60s\n"

h = Harness("pr86", live=(
    "tools/check-docs/main.zig",
    FULL,
    CI,
    "AGENTS.md",
))
cases = []


def case(name, want_red, apply):
    cases.append((name, want_red, apply))


def drop_windows_job(s):
    at = s.index("\n  windows:\n")
    return s[:at + 1]


def swap_last_two_steps(s):
    a = "      - run: zig build check-extract\n"
    b = "      - run: zig build check-report\n"
    assert s.endswith(a + b), "unexpected tail"
    return s[:-len(a + b)] + b + a


# 穴: windows ジョブを丸ごと消す。
case("M1 windows job removed", True, lambda h: h.edit(FULL, drop_windows_job))
# 穴: windows ジョブを Linux で走らせる。チェック名は変わらない。
# 字下げまで含めて一致させる。字下げを含めないと、先頭のコメントの中の
# `runs-on: windows-latest` が書き換わり、ジョブの行は変わらない。
case("M2 windows job runs on ubuntu", True, lambda h: h.edit(
    FULL, lambda s: s.replace("    runs-on: windows-latest\n", "    runs-on: ubuntu-latest\n", 1)))
# 穴: windows ジョブから単体テストの step を消す。
case("M3 windows job drops the unit tests", True, lambda h: h.edit(
    FULL, lambda s: s.replace(TEST_STEP, "", 1)))
# 穴: windows ジョブの単体テストから時間の上限を外す(ci.yml と違う step になる)。
case("M3b windows unit tests lose --test-timeout", True, lambda h: h.edit(
    FULL, lambda s: s.replace(TEST_STEP, "      - run: zig build test --summary all\n", 1)))
# 穴: ci.yml の step を変え、full.yml の windows ジョブを変えない。
case("M5 a ci.yml step changed, the windows job not", True, lambda h: h.edit(
    CI, lambda s: s.replace(
        "      - run: zig build test-scheme\n",
        "      - run: zig build test-scheme --summary all\n", 1)))
# 穴: full.yml の自動の起動を外す(手動だけになる)。
case("T1 full.yml no longer starts on ready", True, lambda h: h.edit(
    FULL, lambda s: s.replace("types: [ready_for_review]", "types: [closed]", 1)))
case("T2 full.yml pull_request trigger removed", True, lambda h: h.edit(
    FULL, lambda s: s.replace("  pull_request:\n    types: [ready_for_review]\n", "", 1)))
# 穴: 手動の起動を外す(ready の後の push のコミットで Full を走らせられなくなる)。
case("T3 full.yml workflow_dispatch removed", True, lambda h: h.edit(
    FULL, lambda s: s.replace("  workflow_dispatch:\n", "", 1)))

# 対照: windows ジョブの step を並べ替える。
case("C1 windows steps reordered", False, lambda h: h.edit(FULL, swap_last_two_steps))
# 対照: windows ジョブだけに step を足す。
case("C2 a step added to the windows job only", False, lambda h: h.edit(
    FULL, lambda s: s + "      - run: zig version\n"))

report(cases, h)
h.reset()
h.drop()
