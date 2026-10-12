#!/usr/bin/env python3
"""Packages the release archives and SHA256SUMS from the output of `zig build dist`.

標準ライブラリだけで動く。入力は `zig-out/dist/<ターゲット>/` の実行ファイル、
`zig-out/web/sucheme.wasm`、`web/`、リポジトリ直下の `LICENSE` と
`THIRD-PARTY-NOTICES.txt` である。ターゲットの一覧は `build.zig` の `dist` step だけが
持つので、このスクリプトは `zig-out/dist/` の下のディレクトリ名から導く。

作るもの(`--out-dir`、既定は `zig-out/release/`):

- `sucheme-v<版>-<ターゲット>.tar.gz`(Linux と macOS)と `.zip`(Windows)。中身は
  `sucheme-v<版>-<ターゲット>/` の下の実行ファイル、`LICENSE`、
  `THIRD-PARTY-NOTICES.txt` である。`.pdb` は入れない。strip もしない。
- `sucheme-web-v<版>.zip`。`web/` の中身と `sucheme.wasm` を同じ階層に並べる。
  展開した先で `node serve.mjs .` と打てば開ける。
- `SHA256SUMS`。`sha256sum -c SHA256SUMS` を out-dir の中で実行して確かめられる。

同じ入力から同じアーカイブを作る。順序は名前順、時刻は固定、権限は実行ファイルが
0755でそれ以外が0644、所有者は空にする。gzip と deflate の出力は zlib の版に
依存するので、バイト単位の一致は同じ Python の環境の中でだけ約束する。

組み立てたあと、アーカイブを開き直して中身を確かめる(`--verify-only` は、この読み直し
だけを行う)。確かめるのは、期待するファイルだけが揃っていること、実行ファイルに実行
ビットがあること、中身が入力と一致すること、チェックサムが一致すること、out-dir に
余計なファイルが無いことである。版は `build.zig.zon` の `.version` から読む。

終了コード: 0は成功。1は入力の不足か、読み直しの検査の失敗。
"""

import argparse
import dataclasses
import gzip
import hashlib
import io
import pathlib
import re
import sys
import tarfile
import zipfile

PROGRAM = "sucheme"
# アーカイブに入れる、リポジトリ直下のファイル。
NOTICE_FILES = ("LICENSE", "THIRD-PARTY-NOTICES.txt")
CHECKSUMS = "SHA256SUMS"
EXE_MODE = 0o755
FILE_MODE = 0o644
# zip が表せる最も古い時刻。時刻を固定するための値である。
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)


class PackageError(Exception):
    """An input is missing or an archive does not hold what it should."""


# ---------------------------------------------------------------------------
# 純粋な判定。ファイルを読まない。
# ---------------------------------------------------------------------------


def parse_version(zon_text: str) -> str:
    """Returns the `.version` string of a build.zig.zon text.

    コメントアウトされた行は読まない。生の検索では、コメントアウトした `.version` が
    本物を覆い隠すからである(build.zig の parseManifest も同じ理由でパースする)。
    """
    found = []
    for line in zon_text.splitlines():
        # 行頭が `.version` でなければ、コメントアウトされた行は合わない。
        stripped = line.strip()
        m = re.fullmatch(r'\.version\s*=\s*"([^"]+)"\s*,?\s*(//.*)?', stripped)
        if m:
            found.append(m.group(1))
    if len(found) != 1:
        raise PackageError("build.zig.zon must have exactly one `.version = \"...\"` line, found %d" % len(found))
    return found[0]


def target_os(target: str) -> str:
    """Returns `linux`, `macos` or `windows` for a target such as `x86_64-windows`."""
    parts = target.split("-")
    for os_name in ("linux", "macos", "windows"):
        if os_name in parts[1:]:
            return os_name
    raise PackageError("cannot tell the operating system of target %r" % target)


def exe_name(target: str) -> str:
    return PROGRAM + (".exe" if target_os(target) == "windows" else "")


def archive_ext(target: str) -> str:
    return "zip" if target_os(target) == "windows" else "tar.gz"


def archive_stem(version: str, target: str) -> str:
    return "%s-v%s-%s" % (PROGRAM, version, target)


def archive_name(version: str, target: str) -> str:
    return "%s.%s" % (archive_stem(version, target), archive_ext(target))


def web_stem(version: str) -> str:
    return "%s-web-v%s" % (PROGRAM, version)


def web_archive_name(version: str) -> str:
    return web_stem(version) + ".zip"


def format_checksums(entries: dict) -> str:
    """Formats `{name: hex digest}` the way `sha256sum` writes it, sorted by name."""
    return "".join("%s  %s\n" % (entries[name], name) for name in sorted(entries))


def parse_checksums(text: str) -> dict:
    """Reads a `sha256sum`-style text into `{name: hex digest}`."""
    entries = {}
    for number, line in enumerate(text.splitlines(), 1):
        m = re.fullmatch(r"([0-9a-f]{64})  ([^/\\ ][^/\\]*)", line)
        if not m:
            raise PackageError("%s line %d is not `<sha256>  <name>`: %r" % (CHECKSUMS, number, line))
        if m.group(2) in entries:
            raise PackageError("%s names %s twice" % (CHECKSUMS, m.group(2)))
        entries[m.group(2)] = m.group(1)
    return entries


# ---------------------------------------------------------------------------
# 入力の読み取り
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True)
class Member:
    """One file of an archive: where it goes, where it comes from, and its mode."""

    arcname: str
    source: pathlib.Path
    mode: int


def discover_targets(dist_dir: pathlib.Path) -> list:
    """Returns the target names, which are the directory names under `dist_dir`."""
    if not dist_dir.is_dir():
        raise PackageError("%s does not exist; run `zig build dist` first" % dist_dir)
    targets = sorted(p.name for p in dist_dir.iterdir() if p.is_dir())
    if not targets:
        raise PackageError("%s has no target directory; `zig build dist` built nothing" % dist_dir)
    return targets


def require_file(path: pathlib.Path) -> pathlib.Path:
    if not path.is_file():
        raise PackageError("%s is missing" % path)
    return path


def target_members(version: str, target: str, root: pathlib.Path) -> list:
    """Lists the files of one target's archive, in the order they are stored."""
    stem = archive_stem(version, target)
    exe = require_file(root / "zig-out" / "dist" / target / exe_name(target))
    members = [Member("%s/%s" % (stem, exe_name(target)), exe, EXE_MODE)]
    for name in NOTICE_FILES:
        members.append(Member("%s/%s" % (stem, name), require_file(root / name), FILE_MODE))
    return sorted(members, key=lambda m: m.arcname)


def web_members(version: str, root: pathlib.Path) -> list:
    """Lists the files of the Web UI archive: `web/`, the wasm file and the notices."""
    stem = web_stem(version)
    web_dir = root / "web"
    if not web_dir.is_dir():
        raise PackageError("%s does not exist" % web_dir)
    members = {}
    for path in sorted(p for p in web_dir.rglob("*") if p.is_file()):
        members[path.relative_to(web_dir).as_posix()] = path
    if "sucheme.wasm" in members:
        raise PackageError("web/ already holds sucheme.wasm, which the build puts there")
    members["sucheme.wasm"] = require_file(root / "zig-out" / "web" / "sucheme.wasm")
    for name in NOTICE_FILES:
        if name in members:
            raise PackageError("web/ already holds %s" % name)
        members[name] = require_file(root / name)
    return [Member("%s/%s" % (stem, rel), members[rel], FILE_MODE) for rel in sorted(members)]


def plan(root: pathlib.Path) -> dict:
    """Returns `{archive name: [Member]}` for every archive this run makes."""
    version = parse_version(require_file(root / "build.zig.zon").read_text(encoding="utf-8"))
    archives = {}
    for target in discover_targets(root / "zig-out" / "dist"):
        archives[archive_name(version, target)] = target_members(version, target, root)
    archives[web_archive_name(version)] = web_members(version, root)
    return archives


# ---------------------------------------------------------------------------
# 書き込み
# ---------------------------------------------------------------------------


def write_tar_gz(path: pathlib.Path, members: list) -> None:
    """Writes a tar.gz whose bytes depend only on the members."""
    with open(path, "wb") as raw:
        # filename を空にし、mtime を0にする。そうしないと gzip の頭に名前と時刻が入る。
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for m in members:
                    data = m.source.read_bytes()
                    info = tarfile.TarInfo(m.arcname)
                    info.size = len(data)
                    info.mtime = 0
                    info.mode = m.mode
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    tar.addfile(info, io.BytesIO(data))


def write_zip(path: pathlib.Path, members: list) -> None:
    """Writes a zip whose bytes depend only on the members."""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for m in members:
            info = zipfile.ZipInfo(m.arcname, date_time=ZIP_EPOCH)
            info.compress_type = zipfile.ZIP_DEFLATED
            # create_system を3(Unix)に固定する。実行する OS で変わらないようにし、
            # 権限を external_attr の上位16ビットに置く。
            info.create_system = 3
            info.external_attr = (0o100000 | m.mode) << 16
            zf.writestr(info, m.source.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def sha256_of(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(root: pathlib.Path, out_dir: pathlib.Path) -> list:
    """Writes every archive and SHA256SUMS into `out_dir`, and returns the archive names."""
    archives = plan(root)
    out_dir.mkdir(parents=True, exist_ok=True)
    sums = {}
    for name, members in archives.items():
        path = out_dir / name
        if name.endswith(".zip"):
            write_zip(path, members)
        else:
            write_tar_gz(path, members)
        sums[name] = sha256_of(path)
    (out_dir / CHECKSUMS).write_text(format_checksums(sums), encoding="utf-8", newline="\n")
    return sorted(archives)


# ---------------------------------------------------------------------------
# 読み直し
# ---------------------------------------------------------------------------


def read_archive(path: pathlib.Path) -> dict:
    """Opens an archive again and returns `{member name: (mode, bytes)}`."""
    files = {}
    if path.name.endswith(".zip"):
        with zipfile.ZipFile(path) as zf:
            bad = zf.testzip()
            if bad is not None:
                raise PackageError("%s: member %s fails its CRC" % (path.name, bad))
            for info in zf.infolist():
                if info.is_dir():
                    continue
                if info.filename in files:
                    raise PackageError("%s: %s appears twice" % (path.name, info.filename))
                files[info.filename] = ((info.external_attr >> 16) & 0o777, zf.read(info))
    else:
        with tarfile.open(path, "r:gz") as tar:
            for info in tar.getmembers():
                if info.isdir():
                    continue
                if not info.isreg():
                    raise PackageError("%s: %s is not a regular file" % (path.name, info.name))
                if info.name in files:
                    raise PackageError("%s: %s appears twice" % (path.name, info.name))
                files[info.name] = (info.mode & 0o777, tar.extractfile(info).read())
    return files


def verify_archive(path: pathlib.Path, members: list) -> None:
    """Fails unless the archive holds exactly `members`, with their bytes and execute bits."""
    if not path.is_file():
        raise PackageError("%s is missing" % path)
    files = read_archive(path)
    want = {m.arcname for m in members}
    missing = sorted(want - files.keys())
    extra = sorted(files.keys() - want)
    if missing:
        raise PackageError("%s lacks %s" % (path.name, ", ".join(missing)))
    if extra:
        raise PackageError("%s holds unexpected %s" % (path.name, ", ".join(extra)))
    for m in members:
        mode, data = files[m.arcname]
        if data != m.source.read_bytes():
            raise PackageError("%s: %s differs from %s" % (path.name, m.arcname, m.source))
        executable = mode & 0o111
        if m.mode & 0o111:
            if executable != 0o111:
                raise PackageError("%s: %s lost its execute bit (mode %o)" % (path.name, m.arcname, mode))
        elif executable:
            raise PackageError("%s: %s is executable (mode %o)" % (path.name, m.arcname, mode))


def verify(root: pathlib.Path, out_dir: pathlib.Path) -> list:
    """Re-reads every archive and SHA256SUMS in `out_dir`, and returns the archive names."""
    archives = plan(root)
    for name, members in archives.items():
        verify_archive(out_dir / name, members)

    sums_path = require_file(out_dir / CHECKSUMS)
    listed = parse_checksums(sums_path.read_text(encoding="utf-8"))
    if listed.keys() != archives.keys():
        raise PackageError(
            "%s lists %s, but the archives are %s" % (CHECKSUMS, sorted(listed), sorted(archives))
        )
    for name in archives:
        actual = sha256_of(out_dir / name)
        if listed[name] != actual:
            raise PackageError("%s: %s says %s, but the file is %s" % (CHECKSUMS, name, listed[name], actual))

    # 余計なファイルは、`gh release create` に渡す束の中身を変えてしまう。
    stray = sorted(p.name for p in out_dir.iterdir() if p.name not in archives and p.name != CHECKSUMS)
    if stray:
        raise PackageError("%s holds files this run did not make: %s" % (out_dir, ", ".join(stray)))
    return sorted(archives)


def main(argv: list) -> int:
    here = pathlib.Path(__file__).resolve()
    parser = argparse.ArgumentParser(description="Package the release archives from `zig build dist`.")
    parser.add_argument("--root", type=pathlib.Path, default=here.parents[2], help="repository root")
    parser.add_argument("--out-dir", type=pathlib.Path, default=None, help="default: <root>/zig-out/release")
    parser.add_argument("--verify-only", action="store_true", help="only re-read the archives already in out-dir")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    out_dir = args.out_dir if args.out_dir is not None else root / "zig-out" / "release"
    try:
        if not args.verify_only:
            build(root, out_dir)
        names = verify(root, out_dir)
    except PackageError as e:
        print("package: error: %s" % e, file=sys.stderr)
        return 1
    for name in names:
        path = out_dir / name
        print("%10d  %s" % (path.stat().st_size, name))
    print("package: %d archives and %s in %s verified" % (len(names), CHECKSUMS, out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
