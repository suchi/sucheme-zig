"""Pages 用のワークフローのキー(`keyIsAllowedIn`)が、呼び出しの配線まで効いているかを確認する。

単体テストは `keyIsAllowedIn` だけを固定する。ワークフローを走査するループが、
その関数にファイルのパスを渡していることは、単体テストでは固定されない。
ここでは、実際のリポジトリの複製に穴を作り、`zig build check-docs` が赤になるかを見る。

3つの組を試す。

- 穴: Pages 専用のキーを pages.yml 以外に置く。赤になること。
- 対照: pages.yml 自身と、共有のキーを足した記述は、緑のままであること。
- ミューテーション: 走査のループが `keyIsAllowedIn(path, key)` の代わりに
  `keyIsAllowedIn(pages_workflow, key)` を呼ぶ形に壊すと、穴が緑になる。
  このスクリプトの穴の組が、そのとき赤にならないこと(= 検出できること)を示す。

使い方(作業ツリーで使うときは SUCHEME_ROOT を指定する):

    python tools/review-harness/scenarios/pages-workflow.py > out.txt 2>&1
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from harness import Harness, first_line

CI = ".github/workflows/ci.yml"
FULL = ".github/workflows/full.yml"
RELEASE = ".github/workflows/release.yml"
PREVIEW = ".github/workflows/preview.yml"
PAGES = ".github/workflows/pages.yml"
CHECKER = "tools/check-docs/main.zig"

WIRING = "if (!keyIsAllowedIn(path, key)) {"
WIRING_MUTATED = "if (!keyIsAllowedIn(pages_workflow, key)) {"

h = Harness("pages", live=(CHECKER, PAGES, "docs/adr/README.md"))


def add_before_runs_on(extra):
    """最初の `runs-on:` の行の前に、ジョブのキーを1行足す。"""
    def f(s):
        i = s.index("    runs-on:")
        return s[:i] + extra + s[i:]
    return f


def say(ok, name, code, out):
    print(f"{'OK' if ok else 'BAD':<4} {name:<50} exit={code}  {first_line(out)[:70]}")


def skipped(name, why):
    print(f"{'??':<4} {name:<50} (edit skipped: {why})")


hole_cases = [
    ("H1 needs in ci.yml", CI, add_before_runs_on("    needs: other\n")),
    ("H2 needs in full.yml", FULL, add_before_runs_on("    needs: other\n")),
    ("H3 environment in release.yml", RELEASE, add_before_runs_on("    environment: github-pages\n")),
    ("H4 environment in preview.yml", PREVIEW, add_before_runs_on("    environment: github-pages\n")),
    ("H5 id-token in ci.yml", CI, lambda s: s.replace(
        "permissions:\n  contents: read\n", "permissions:\n  contents: read\n  id-token: write\n", 1)),
]

# 対照: 緑のままの記述。
controls = [
    ("C1 pages.yml as committed", PAGES, None),
    ("C2 a shared key added to ci.yml", CI, add_before_runs_on("    timeout-minutes: 60\n")),
    ("C3 a shared key added to pages.yml", PAGES, add_before_runs_on("    timeout-minutes: 11\n")),
]

code, out = h.run()
say(code == 0, "baseline", code, out)

# 穴: Pages 専用のキーが、pages.yml 以外では赤になる。
for name, path, fn in hole_cases:
    h.reset()
    try:
        h.edit(path, fn)
    except (AssertionError, ValueError) as e:
        skipped(name, e)
        continue
    code, out = h.run()
    say(code != 0, name, code, out)

for name, path, fn in controls:
    h.reset()
    if fn is not None:
        try:
            h.edit(path, fn)
        except (AssertionError, ValueError) as e:
            skipped(name, e)
            continue
    code, out = h.run()
    say(code == 0, name, code, out)

# ミューテーション: 配線を壊した検査ツールでは、穴が緑になる。壊れた検査ツールが
# 穴を見逃す(緑になる)なら、上の穴の組は、配線の破損を検出できる。
for name, path, fn in hole_cases[:2]:
    h.reset()
    try:
        h.edit(CHECKER, lambda s: s.replace(WIRING, WIRING_MUTATED, 1))
        h.edit(path, fn)
    except (AssertionError, ValueError) as e:
        skipped("M1 " + name, e)
        continue
    code, out = h.run()
    say(code == 0, "M1 wiring broken, " + name, code, out)

h.reset()
h.drop()
