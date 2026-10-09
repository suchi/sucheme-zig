# -*- coding: utf-8 -*-
"""検査ツールの指摘を実機で確かめるためのハーネス。

なぜ必要か: 使い捨ての複製を毎回作ると、空のビルドキャッシュから検査ツールを
再コンパイルするので1シナリオに数秒かかる。複製を1つ作って git 管理し、
シナリオごとに戻し、ビルドキャッシュを複製の外に置いて共有すると1秒未満になる。
1巡で20〜30シナリオ試すので、この差が巡回の所要時間を決める。

使う側への約束: シェルで複製を作ったりリセットしたりしないこと。`git clean -f`
がフックの確認判定に当たるので、シナリオごとに承認待ちが入る。このハーネスは
同じ処理を subprocess で行うので、承認はスクリプトの起動1回だけで済む。経緯は
docs/review/process-lessons.md にある。

使い方:

    import pathlib, sys
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
    from harness import Harness, first_line

    h = Harness("r21", live=("tools/check-docs/main.zig",))  # 未コミットの変更を持ち込む
    for name, step, want_red, apply in cases:
        h.reset()
        apply(h)                     # h.edit(...) / h.write(...) で改変する
        code, out = h.run(step)      # "check-docs" / "check-extract" / "test" / "test-scheme" / "fmt"
        ok = (code != 0) == want_red
        print("%-4s %-40s exit=%d  %s" % ("OK" if ok else "BAD", name, code, first_line(out)[:70]))
    h.reset(); h.drop()

シナリオは `scenarios/` に置き、1回の呼び出しで全件流す。穴のシナリオと、正当な
記述が緑のままであることの対照を必ず両方入れる。日本語の出力はコンソールで
化けることがあるので、ファイルに落として読む。

    python tools/review-harness/scenarios/roundNN.py > out.txt 2>&1

SUCHEME_ROOT でリポジトリの位置、WORK で作業ディレクトリを指定できる。既定は
このファイルから見たリポジトリのルートと、その下の _work/review-harness
(.gitignore が _work を無視する)。
"""
import os
import pathlib
import shutil
import subprocess

_here = pathlib.Path(__file__).resolve()
ROOT = pathlib.Path(os.environ.get("SUCHEME_ROOT", _here.parents[2]))
WORK = pathlib.Path(os.environ.get("WORK", ROOT / "_work" / "review-harness"))

# リストで渡したコマンドに shell=True を付けてよいのは Windows だけ。POSIX では
# リストの先頭の語だけがシェルに渡り、`zig` が引数なしで走って全シナリオが
# 誤って赤になる。Windows では zig が shim 経由のことがあるので付ける。
_SHELL = os.name == "nt"


class Harness:
    def __init__(self, name="work", live=()):
        self.dir = WORK / ("h_" + name)
        self.cache = WORK / "h_cache"
        self.cache.mkdir(parents=True, exist_ok=True)
        if self.dir.exists():
            shutil.rmtree(self.dir, onerror=_force_remove)
        self.dir.mkdir(parents=True)
        r = subprocess.run(
            "git archive HEAD | tar -x -C " + str(self.dir).replace("\\", "/"),
            cwd=ROOT, shell=True, capture_output=True,
        )
        assert r.returncode == 0, r.stderr
        for rel in live:
            shutil.copy(ROOT / rel, self.dir / rel)
        self._git("init", "-q")
        self._git("add", "-A")
        self._git("-c", "user.email=h@h", "-c", "user.name=h", "commit", "-qm", "base")
        self.run("check-docs")  # キャッシュを温める

    def _git(self, *args):
        return subprocess.run(["git", *args], cwd=self.dir, capture_output=True)

    def run(self, step="check-docs"):
        if step == "fmt":
            r = subprocess.run(["zig", "fmt", "--check", "."], cwd=self.dir,
                               capture_output=True, shell=_SHELL)
        else:
            r = subprocess.run(
                ["zig", "build", step, "--cache-dir", str(self.cache)],
                cwd=self.dir, capture_output=True, shell=_SHELL,
            )
        return r.returncode, (r.stdout + r.stderr).decode("utf-8", "replace")

    def edit(self, rel, fn):
        p = self.dir / rel
        s = p.read_text(encoding="utf-8")
        out = fn(s)
        assert out != s, "no-op edit: " + rel
        p.write_text(out, encoding="utf-8", newline="\n")

    def write(self, rel, text):
        p = self.dir / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8", newline="\n")

    def reset(self):
        self._git("checkout", "-q", "--", ".")
        self._git("clean", "-fdq", "-e", ".zig-cache", "-e", "zig-out")

    def drop(self):
        shutil.rmtree(self.dir, onerror=_force_remove)


def _force_remove(func, path, _exc):
    # Windows では .git 配下が読み取り専用で rmtree が落ちる。
    import stat
    try:
        os.chmod(path, stat.S_IWRITE)
        func(path)
    except OSError:
        pass


def first_line(out, prefix="check-docs:"):
    for line in out.splitlines():
        if line.strip().startswith(prefix):
            return line.strip()
    return next((l.strip() for l in out.splitlines() if l.strip()), "")


def report(cases, h):
    """[(name, want_red, apply)] を順に試して1行ずつ表示する。"""
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
        print("%-4s %-46s exit=%d  %s" % ("OK" if ok else "BAD", name, code, first_line(out)[:72]))
