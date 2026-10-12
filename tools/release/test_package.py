"""Unit tests for package.py. Run with `python3 -m unittest discover -s tools/release`."""

import gzip
import io
import os
import pathlib
import shutil
import tarfile
import tempfile
import unittest
import zipfile

import package

ZON = """.{
    .name = .sucheme,
    // .version = "9.9.9",
    .version = "0.1.0-dev",
    .fingerprint = 0x1,
}
"""


class PureFunctions(unittest.TestCase):
    def test_parse_version_reads_the_live_line_not_the_comment(self):
        self.assertEqual(package.parse_version(ZON), "0.1.0-dev")

    def test_parse_version_needs_exactly_one_line(self):
        with self.assertRaises(package.PackageError):
            package.parse_version(".{ .name = .sucheme }")
        with self.assertRaises(package.PackageError):
            package.parse_version('    .version = "1.0.0",\n    .version = "2.0.0",\n')

    def test_target_os(self):
        self.assertEqual(package.target_os("x86_64-linux-musl"), "linux")
        self.assertEqual(package.target_os("aarch64-linux-musl"), "linux")
        self.assertEqual(package.target_os("aarch64-macos"), "macos")
        self.assertEqual(package.target_os("x86_64-windows"), "windows")
        with self.assertRaises(package.PackageError):
            package.target_os("x86_64-freebsd")

    def test_target_os_does_not_read_the_architecture(self):
        # 先頭は CPU アーキテクチャである。そこに OS の名前が現れても OS ではない。
        with self.assertRaises(package.PackageError):
            package.target_os("windows")

    def test_names_follow_the_target(self):
        self.assertEqual(package.archive_name("0.1.0", "x86_64-linux-musl"), "sucheme-v0.1.0-x86_64-linux-musl.tar.gz")
        self.assertEqual(package.archive_name("0.1.0", "aarch64-macos"), "sucheme-v0.1.0-aarch64-macos.tar.gz")
        self.assertEqual(package.archive_name("0.1.0", "aarch64-windows"), "sucheme-v0.1.0-aarch64-windows.zip")
        self.assertEqual(package.exe_name("x86_64-windows"), "sucheme.exe")
        self.assertEqual(package.exe_name("x86_64-macos"), "sucheme")
        self.assertEqual(package.web_archive_name("0.1.0"), "sucheme-web-v0.1.0.zip")

    def test_checksums_round_trip_and_sort(self):
        a, b = "a" * 64, "b" * 64
        text = package.format_checksums({"z.zip": a, "a.tar.gz": b})
        self.assertEqual(text, "%s  a.tar.gz\n%s  z.zip\n" % (b, a))
        self.assertEqual(package.parse_checksums(text), {"z.zip": a, "a.tar.gz": b})

    def test_parse_checksums_rejects_what_sha256sum_would_not_read(self):
        for bad in ("abc  x\n", "%s x\n" % ("a" * 64), "%s  dir/x\n" % ("a" * 64)):
            with self.assertRaises(package.PackageError, msg=bad):
                package.parse_checksums(bad)
        twice = ("%s  x\n" % ("a" * 64)) * 2
        with self.assertRaises(package.PackageError):
            package.parse_checksums(twice)


class Tree:
    """A temporary repository root with the inputs package.py reads."""

    TARGETS = ("x86_64-linux-musl", "aarch64-macos", "x86_64-windows")

    def __init__(self, tmp: pathlib.Path):
        self.root = tmp / "repo"
        (self.root / "web").mkdir(parents=True)
        (self.root / "zig-out" / "web").mkdir(parents=True)
        (self.root / "build.zig.zon").write_text(ZON)
        (self.root / "LICENSE").write_text("license\n")
        (self.root / "THIRD-PARTY-NOTICES.txt").write_text("notices\n")
        (self.root / "web" / "index.html").write_text("<html>\n")
        (self.root / "web" / "serve.mjs").write_text("// serve\n")
        (self.root / "zig-out" / "web" / "sucheme.wasm").write_bytes(b"\0asm\1\0\0\0")
        for target in self.TARGETS:
            d = self.root / "zig-out" / "dist" / target
            d.mkdir(parents=True)
            (d / package.exe_name(target)).write_bytes(("exe " + target).encode() * 100)
        # .pdb は入れない。
        (self.root / "zig-out" / "dist" / "x86_64-windows" / "sucheme.pdb").write_bytes(b"pdb")
        self.out = tmp / "out"


class Packaging(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tree = Tree(pathlib.Path(self._tmp.name))

    def build(self, out=None):
        return package.build(self.tree.root, out or self.tree.out)

    def test_build_makes_one_archive_per_target_and_the_web_zip(self):
        names = self.build()
        self.assertEqual(
            names,
            [
                "sucheme-v0.1.0-dev-aarch64-macos.tar.gz",
                "sucheme-v0.1.0-dev-x86_64-linux-musl.tar.gz",
                "sucheme-v0.1.0-dev-x86_64-windows.zip",
                "sucheme-web-v0.1.0-dev.zip",
            ],
        )
        self.assertEqual(package.verify(self.tree.root, self.tree.out), names)

    def test_archives_hold_the_executable_and_the_notices_but_not_the_pdb(self):
        self.build()
        files = package.read_archive(self.tree.out / "sucheme-v0.1.0-dev-x86_64-windows.zip")
        self.assertEqual(
            sorted(files),
            [
                "sucheme-v0.1.0-dev-x86_64-windows/LICENSE",
                "sucheme-v0.1.0-dev-x86_64-windows/THIRD-PARTY-NOTICES.txt",
                "sucheme-v0.1.0-dev-x86_64-windows/sucheme.exe",
            ],
        )
        mode, _ = package.read_archive(self.tree.out / "sucheme-v0.1.0-dev-aarch64-macos.tar.gz")[
            "sucheme-v0.1.0-dev-aarch64-macos/sucheme"
        ]
        self.assertEqual(mode, 0o755)

    def test_web_zip_puts_the_wasm_beside_the_web_files(self):
        self.build()
        files = package.read_archive(self.tree.out / "sucheme-web-v0.1.0-dev.zip")
        self.assertEqual(
            sorted(files),
            [
                "sucheme-web-v0.1.0-dev/LICENSE",
                "sucheme-web-v0.1.0-dev/THIRD-PARTY-NOTICES.txt",
                "sucheme-web-v0.1.0-dev/index.html",
                "sucheme-web-v0.1.0-dev/serve.mjs",
                "sucheme-web-v0.1.0-dev/sucheme.wasm",
            ],
        )

    def test_same_input_gives_the_same_bytes(self):
        self.build(self.tree.out)
        second = self.tree.out.parent / "out2"
        self.build(second)
        for p in sorted(self.tree.out.iterdir()):
            self.assertEqual(p.read_bytes(), (second / p.name).read_bytes(), p.name)

    def test_modification_times_and_modes_of_the_sources_do_not_leak_in(self):
        self.build(self.tree.out)
        exe = self.tree.root / "zig-out" / "dist" / "x86_64-linux-musl" / "sucheme"
        os.chmod(exe, 0o700)
        os.utime(exe, (1_000_000_000, 1_000_000_000))
        second = self.tree.out.parent / "out2"
        self.build(second)
        name = "sucheme-v0.1.0-dev-x86_64-linux-musl.tar.gz"
        self.assertEqual((self.tree.out / name).read_bytes(), (second / name).read_bytes())

    def test_members_are_stored_in_name_order_with_fixed_times(self):
        self.build()
        with tarfile.open(self.tree.out / "sucheme-v0.1.0-dev-aarch64-macos.tar.gz") as tar:
            infos = tar.getmembers()
        self.assertEqual([i.name for i in infos], sorted(i.name for i in infos))
        self.assertEqual({i.mtime for i in infos}, {0})
        self.assertEqual({(i.uid, i.gid, i.uname, i.gname) for i in infos}, {(0, 0, "", "")})
        with zipfile.ZipFile(self.tree.out / "sucheme-web-v0.1.0-dev.zip") as zf:
            infos = zf.infolist()
        self.assertEqual([i.filename for i in infos], sorted(i.filename for i in infos))
        self.assertEqual({i.date_time for i in infos}, {(1980, 1, 1, 0, 0, 0)})

    def test_gzip_header_has_no_name_or_time(self):
        self.build()
        head = (self.tree.out / "sucheme-v0.1.0-dev-aarch64-macos.tar.gz").read_bytes()[:10]
        self.assertEqual(head[3], 0, "FLG: no file name")
        self.assertEqual(head[4:8], b"\0\0\0\0", "MTIME")

    def test_missing_executable_is_reported(self):
        (self.tree.root / "zig-out" / "dist" / "aarch64-macos" / "sucheme").unlink()
        with self.assertRaises(package.PackageError):
            self.build()

    def test_empty_dist_is_reported(self):
        shutil.rmtree(self.tree.root / "zig-out" / "dist")
        (self.tree.root / "zig-out" / "dist").mkdir()
        with self.assertRaises(package.PackageError):
            self.build()


def rewrite_tar(path: pathlib.Path, change):
    """Rewrites a tar.gz, letting `change(info, data)` return a new (info, data) or None."""
    out = io.BytesIO()
    with tarfile.open(path, "r:gz") as src, gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as dst:
            for info in src.getmembers():
                data = src.extractfile(info).read()
                changed = change(info, data)
                if changed is not None:
                    dst.addfile(changed[0], io.BytesIO(changed[1]))
    path.write_bytes(out.getvalue())


class Verification(unittest.TestCase):
    """The re-read has to fail on archives that are wrong."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tree = Tree(pathlib.Path(self._tmp.name))
        package.build(self.tree.root, self.tree.out)
        self.linux = self.tree.out / "sucheme-v0.1.0-dev-x86_64-linux-musl.tar.gz"

    def assert_fails(self, text):
        with self.assertRaises(package.PackageError) as cm:
            package.verify(self.tree.root, self.tree.out)
        self.assertIn(text, str(cm.exception))

    def test_a_clean_build_passes(self):
        package.verify(self.tree.root, self.tree.out)

    def test_lost_execute_bit(self):
        def change(info, data):
            if info.name.endswith("/sucheme"):
                info.mode = 0o644
            return info, data

        rewrite_tar(self.linux, change)
        self.assert_fails("execute bit")

    def test_missing_file(self):
        rewrite_tar(self.linux, lambda info, data: None if info.name.endswith("LICENSE") else (info, data))
        self.assert_fails("lacks")

    def test_extra_file(self):
        # 余分なメンバーを足した tar を作る。
        out = io.BytesIO()
        with tarfile.open(self.linux, "r:gz") as src, gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w") as dst:
                for info in src.getmembers():
                    dst.addfile(info, src.extractfile(info))
                extra = tarfile.TarInfo("sucheme-v0.1.0-dev-x86_64-linux-musl/sucheme.pdb")
                extra.size = 3
                dst.addfile(extra, io.BytesIO(b"pdb"))
        self.linux.write_bytes(out.getvalue())
        self.assert_fails("unexpected")

    def test_changed_content(self):
        def change(info, data):
            return info, (b"x" + data[1:] if info.name.endswith("LICENSE") else data)

        rewrite_tar(self.linux, change)
        self.assert_fails("differs")

    def test_checksum_that_does_not_match(self):
        sums = self.tree.out / package.CHECKSUMS
        text = sums.read_text()
        sums.write_text(text.replace(text[:1], "0" if text[0] != "0" else "1", 1))
        self.assert_fails("says")

    def test_archive_missing_from_the_checksums(self):
        sums = self.tree.out / package.CHECKSUMS
        lines = sums.read_text().splitlines(keepends=True)
        sums.write_text("".join(lines[1:]))
        self.assert_fails("lists")

    def test_stray_file_in_the_out_dir(self):
        (self.tree.out / "sucheme-v0.0.9-x86_64-linux-musl.tar.gz").write_bytes(b"old")
        self.assert_fails("did not make")

    def test_zip_without_the_executable(self):
        windows = self.tree.out / "sucheme-v0.1.0-dev-x86_64-windows.zip"
        with zipfile.ZipFile(windows) as src:
            kept = [(i, src.read(i)) for i in src.infolist() if not i.filename.endswith(".exe")]
        with zipfile.ZipFile(windows, "w") as dst:
            for info, data in kept:
                dst.writestr(info, data)
        self.assert_fails("lacks")


if __name__ == "__main__":
    unittest.main()
