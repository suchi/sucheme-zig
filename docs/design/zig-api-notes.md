# Zig 0.17.0 API ノート

Zig 0.17.0 は2026-10-01リリースで、0.14以前と比べて標準ライブラリとビルドシステムの API が大きく変わっている。古い記法を書くと必ずコンパイルエラーになるため、実装前にこのドキュメントを読む。

本ドキュメントの記載は、特記のない限り Zig 0.17.0 の実機で動作を確認したものである。確認していない事項には「未確認」と明記する。

対応する決定: [ADR-0001](../adr/0001-zig-version-pinning.md)。

## 前提

- 固定バージョン: 0.17.0。`.zigversion` と `build.zig.zon` の `minimum_zig_version` に記録する。
- 確認コマンド: `zig version`
- 標準ライブラリのソースは手元にある。迷ったら `$(dirname $(which zig))/../lib/std/` を読む。これが一次情報である。

## よく使う記法の対応表

| 用途 | 0.14以前のよくある記法 | 0.17.0 での記法 |
| --- | --- | --- |
| エントリポイント | `pub fn main() !void` | `pub fn main(init: std.process.Init) !void` |
| コマンドライン引数 | `std.process.argsAlloc(gpa)` | `init.minimal.args.toSlice(arena)` |
| 標準出力 | `std.io.getStdOut().writer()` | `std.Io.File.Writer.init(.stdout(), io, &buf)` の `.interface` |
| カレントディレクトリ | `std.fs.cwd()` | `std.Io.Dir.cwd()` |
| ファイルを開く | `dir.openFile(path, .{})` | `dir.openFile(io, path, .{})` |
| ファイルを閉じる | `file.close()` | `file.close(io)` |
| 可変長配列 | `std.ArrayList(T).init(gpa)` | `var l: std.ArrayList(T) = .empty;` と `l.append(gpa, x)` |
| 連想配列 | `std.AutoHashMap(K,V).init(gpa)` | `var m: std.AutoHashMapUnmanaged(K,V) = .empty;` と `m.put(gpa, k, v)` |
| 配列への書き込み | `list.writer()` | `std.Io.Writer.Allocating` |
| パニックハンドラ | `pub fn panic(msg, trace, ra)` | `pub const panic = std.debug.FullPanic(myFn)` |
| 省略可能型の書式 | `{?d}` | `{?}` |

`std.fs` はほぼ空になっており、ディレクトリとファイルの操作は `std.Io.Dir` と `std.Io.File` に移っている。`std.io` ではなく `std.Io` である(大文字の I)。

## エントリポイントと標準入出力

```zig
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator(); // プロセスと同じ寿命のアリーナ
    const io = init.io;                   // 入出力を行うには Io が必要

    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;

    try out.print("args={d}\n", .{args.len});
    try out.flush(); // 忘れると出力されない
}
```

`flush` を忘れると何も出力されない。これは最も頻発する誤りである。

## ファイルの読み込み

```zig
const cwd = std.Io.Dir.cwd();

// 全体を一度に読む
const content = try cwd.readFileAlloc(io, "foo.scm", gpa, .unlimited);
defer gpa.free(content);

// Reader 経由で読む
var f = try cwd.openFile(io, "foo.scm", .{});
defer f.close(io);
var buf: [4096]u8 = undefined;
var fr: Io.File.Reader = .init(f, io, &buf);
const all = try fr.interface.allocRemaining(gpa, .unlimited);
```

## 標準入力の行読み取り

```zig
var buf: [4096]u8 = undefined;
var fr: Io.File.Reader = .init(.stdin(), io, &buf);
while (true) {
    const line = fr.interface.takeDelimiterExclusive('\n') catch |e| switch (e) {
        error.EndOfStream => break,
        else => return e,
    };
    // line は次の読み取りで無効になる。保持するならコピーする
}
```

`takeDelimiterExclusive` が返すスライスは内部バッファを指す。次の読み取りで無効になるので、保持する場合はコピーする。

## コレクション

`ArrayList` と `HashMap` は非管理型(アロケータを保持しない)になっており、操作のたびにアロケータを渡す。

```zig
var l: std.ArrayList(u32) = .empty;
defer l.deinit(gpa);
try l.append(gpa, 1);
try l.appendSlice(gpa, &.{ 2, 3 });
try l.ensureTotalCapacity(gpa, 16);
l.appendAssumeCapacity(4);
const last: ?u32 = l.last();   // 省略可能型を返す
const popped: ?u32 = l.pop();  // 省略可能型を返す
const owned = try l.toOwnedSlice(gpa);

var m: std.AutoHashMapUnmanaged(u32, u32) = .empty;
defer m.deinit(gpa);
try m.put(gpa, 1, 10);

var s: std.StringHashMapUnmanaged(u32) = .empty;
defer s.deinit(gpa);
try s.put(gpa, "key", 5);
```

`last()` と `pop()` が省略可能型を返す点に注意する。0.14以前は `pop()` が値を返し `popOrNull()` が省略可能型を返していた。

## 文字列の組み立て

`ArrayList` に `writer()` メソッドはない。`std.Io.Writer.Allocating` を使う。

```zig
var aw: std.Io.Writer.Allocating = .init(gpa);
defer aw.deinit();
try aw.writer.print("hello {s}", .{"world"});
const result = aw.written();
```

既存の `ArrayList` に書き込む場合は `.fromArrayList(gpa, &list)` を使う。この場合 `list.items` は更新されないので、結果は `aw.written()` で取る。`deinit` を忘れると漏れる。

`std.fmt.allocPrint(gpa, fmt, args)` は従来どおり使える。

## パニックハンドラ

ルートソースファイルに小文字の `panic` という名前空間を置く。

```zig
pub const panic = std.debug.FullPanic(myPanic);

fn myPanic(msg: []const u8, _: ?usize) noreturn {
    // ホストに通知してから停止する
    @trap();
}
```

名前が小文字の `panic` であること、値が型(名前空間)であることの両方が必要である。大文字の `Panic` は無視され、既定のハンドラが使われる(実機で確認した)。古い `pub fn panic(msg, trace, ra)` の形も互換のため受理されるが非推奨である。

## 多倍長整数

```zig
var a = try std.math.big.int.Managed.initSet(gpa, @as(u64, 1));
defer a.deinit();
var two = try std.math.big.int.Managed.initSet(gpa, @as(u64, 2));
defer two.deinit();
try a.mul(&a, &two);
const s = try a.toString(gpa, 10, .lower); // 基数指定の文字列化
defer gpa.free(s);
```

`mul` は `*const Managed` を取る。`toConst()` を渡すとエラーになる。

## 浮動小数点の書式

`{d}` と `{e}` はどちらも「読み戻して同じ値になる最短表現」を与える(0.1、1/3、1e300、5e-324 で確認した)。ただし Scheme の記法とは異なる。

| 値 | `{d}` | `{e}` |
| --- | --- | --- |
| 0.1 | `0.1` | `1e-1` |
| 100.0 | `100` | `1e2` |
| 1e300 | 301桁の十進表記 | `1e300` |

`std.math.inf(f64)` は `inf`、NaN は `nan` と出力される。Scheme の `+inf.0` 形式へは自前で変換する。

`std.fmt.parseFloat(f64, s)` は `1.0` `.5` `5.` `1e-5` `inf` `-inf` `nan` を受理する。

## 端末

`std.Io.Terminal` は色付き出力のための書き込み側の抽象であり、入力の生モードは提供しない。段階7の行編集では `file.isTty(io)` と `file.enableAnsiEscapeCodes(io)` を使い、生モードの設定は自前のプラットフォーム別コードで行う。

## テストとファジング

```zig
test "名前" {
    try std.testing.expectEqual(@as(i32, 10), add(3, 7));
}

test "ファジング" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    while (!smith.eos()) {
        const n = smith.value(u8);
        _ = n;
    }
}
```

`zig build test --fuzz -Doptimize=ReleaseFast` でファジングを走らせる。入力生成器は `std.testing.Smith` という名前である。リーダの頑健性検査に使う。

## ビルドスクリプト

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("sucheme", .{
        .root_source_file = b.path("src/sucheme.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "sucheme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sucheme", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs(); // zig build run -- 引数
    b.step("run", "REPL を起動する").dependOn(&run.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "テストを実行する");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
}
```

要点。

- 実行ファイルは `root_module` を取る。`root_source_file` を直接渡す記法はない。
- `addTest` もモジュール単位である。テスト実行ファイルは1度に1モジュールしか対象にできないため、モジュールごとに `addTest` を作る。
- `addPassthruArgs()` が `zig build run -- args` の引数転送を行う。

## WebAssembly のビルド

```zig
const wasm_target = b.resolveTargetQuery(.{
    .cpu_arch = .wasm32,
    .os_tag = .freestanding,
});
const wasm = b.addExecutable(.{
    .name = "sucheme",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    }),
});
wasm.entry = .disabled;  // エントリポイントを持たない
wasm.rdynamic = true;    // export した関数を公開する
b.installArtifact(wasm);
```

WASM 側のコードでは次が使える。

```zig
const gpa = std.heap.wasm_allocator;                      // freestanding で動作する
extern "env" fn host_write(ptr: [*]const u8, len: usize) void;
export fn alloc(n: usize) ?[*]u8 { ... }
```

`export fn` で公開した関数と `extern "env"` の import、線形メモリ越しの文字列の受け渡しは、Node 上で動作を確認した。

## build.zig.zon

```zig
.{
    .name = .sucheme,                      // 識別子リテラル。文字列ではない
    .version = "0.1.0",
    .fingerprint = 0x0,                    // 後述
    .minimum_zig_version = "0.17.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "src", "lib", "LICENSE", "README.md" },
}
```

`fingerprint` はパッケージ名と結びついた値である。誤った値を書くとビルドが失敗し、エラーメッセージが正しい値を教えてくれるので、それを貼る。この値は一度決めたら変更しない(フォークの検出に使われる)。

## 言語側の変更

リリースノートに記載があり、実装中に遭遇する可能性があるもの。印のない項目は未確認である。

- `@intFromEnum` と `@enumFromInt` は0.17.0でも使える(確認済み)。リリースノートには `@backingInt` と `@fromBackingInt` への改名が記載されているが、旧名も受理される。
- `@bitCast` は論理ビット表現の再解釈になり、`extern struct` を含む変換は禁止された。`@ptrCast` を使う。
- `void{}` は書けない。`{}` と書く。
- `errdefer |err|` の捕捉構文は削除された。
- `[1]u8 ** n` による配列の繰り返しは `@splat` に置き換わった。
- 型情報の反映は `@typeInfo(S).@"struct".fields` から `info.field_names` と `info.field_types` の並列反復に変わった。
- `std.fmt.allocPrint` は使えるが、アリーナに対しては `arena.print()` が推奨されている。

## 更新手順

Zig のバージョンを上げるときは次の順で行う。

1. 新バージョンのリリースノートを読み、本ドキュメントの対応表に差分を追記する。
2. `.zigversion`、`build.zig.zon` の `minimum_zig_version`、CI のワークフローを同時に更新する。
3. `zig build test` と `zig build wasm` と `zig fmt --check` を通す。
4. 本ドキュメントの「前提」のバージョン表記を更新し、確認済みと未確認の印を見直す。

これらを1つの PR で行い、バージョン更新だけのコミットに分ける。
