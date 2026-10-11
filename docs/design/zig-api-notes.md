# Zig 0.17.0 API ノート

Zig 0.17.0 は2026-10-01リリースで、0.14以前と比べて標準ライブラリとビルドシステムの API が大きく変わっている。実装前にこのドキュメントを読む。

古い記法の多くはコンパイルエラーになるが、すべてではない。実機で確認した例外を挙げる。

- `std.AutoHashMap(K, V).init(gpa)` と `std.StringHashMap(V).init(gpa)` は動作する。管理型が残っているため、非管理型へ移していないコードがそのまま通る。
- `pub fn panic(msg, trace, ra)` の形も互換のため受理される。
- `ArrayListUnmanaged` と `DynamicBitSetUnmanaged` は非推奨の別名だが、コンパイルは通る。

したがって「コンパイラが古い記法を全部止めてくれる」という前提は置けない。下の対応表を参照して書く。

本ドキュメントの記載は、特記のない限り Zig 0.17.0 の実機で動作を確認したものである。確認していない事項には「未確認」と明記する。

対応する決定: [ADR-0001](../adr/0001-zig-version-pinning.md)。

## 前提

- 固定バージョン: 0.17.0。正は `.zigversion` で、機械が読む複製は `build.zig.zon` の `minimum_zig_version` と `.github/workflows/*.yml` の2箇所である(下の更新手順を参照)。
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
| 省略可能型の書式 | `{d}` | `{?}` または `{?d}` |

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

省略可能型を書式に渡すときは `?` 接頭辞を付ける。`{d}` を省略可能型に直接適用すると `invalid format string 'd' for type '?u32'` になる。`{?}` と `{?d}` と `{?s}` はいずれも有効で、`?` の後ろの指定子はペイロードに適用される(実機で確認)。`pop()` の戻り値をそのまま `{d}` に渡す形が最も踏みやすい。

非管理型の別名のうち `ArrayListUnmanaged` と `DynamicBitSetUnmanaged` は非推奨である。標準ライブラリのソースが前者に `Deprecated; use ArrayList`、後者に `Deprecated: use bit_set.Dynamic` と記している。新しく書くコードでは `std.ArrayList(T)` と `std.bit_set.Dynamic` を使う。

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

## Windows の引数と環境変数の符号化

Windows は引数と環境変数を UTF-16 で渡す。Zig 0.17.0 の標準ライブラリは、これを UTF-8 ではなく WTF-8 に変換する。WTF-8 は、対になっていないサロゲート(U+D800 から U+DFFF)も3バイトで符号化できる UTF-8 の上位集合である。したがって、変換の結果は UTF-8 として妥当でない並びを含みうる。

この節の確認は、標準ライブラリのソースを読んだものと、Linux 上の単体テストで実行したものに分かれる。Windows 実機では何も実行していない。

ソースで確認したこと(`lib/std/process/Args.zig`、`lib/std/process/Environ.zig`、`lib/std/unicode.zig`):

- Windows では `std.process.Args.Vector` が `[]const u16`(WTF-16)になる。
- `Args.toSlice` と `Args.Iterator` の Windows 実装は、コマンドラインを WTF-8 に変換して返す。バッファの大きさは `std.unicode.calcWtf8Len` で求め、1つの UTF-16 の符号単位ごとに `std.unicode.wtf8Encode` で書く。ドキュメントコメントは「On Windows, the result is encoded as WTF-8」と書いている。Windows 以外では「opaque sequence of bytes with no particular encoding」で、符号化の保証がない。
- 上位サロゲートに下位サロゲートが続くときは、対として UTF-8 の4バイトに直す(`emitCharacter`)。したがって、対になった文字は妥当な UTF-8 になる。不対のサロゲートだけが3バイトのまま残る。
- 環境変数は `Environ.Map.putWindowsBlock` が `unicode.wtf16LeToWtf8Alloc` で、キーと値の両方を WTF-8 に変換する。
- `std.unicode.wtf8ValidateSlice` は、WTF-8 として妥当かを調べる。サロゲートを許し、対になっているかは調べない。
- `std.unicode.utf8ValidateSlice` は、UTF-8 として妥当かを調べる。サロゲートの符号化は拒否する。

Linux 上の単体テストで実行したこと(Windows の変換関数そのものではなく、同じ標準ライブラリの変換と検査の関数を、WTF-16 の入力に直接適用した):

- `std.unicode.wtf16LeToWtf8` は、`a`・U+D800・`b` の WTF-16 を5バイト(`61 ED A0 80 62`)に変換する。長さは `calcWtf8Len` の値と一致する。
- その結果を `utf8ValidateSlice` に渡すと false になり、`wtf8ValidateSlice` に渡すと true になる(`"\xed\xa0\x80"` 単体でも同じ)。
- 対になったサロゲート(U+D801 U+DC37)は4バイトの UTF-8 に変換され、`utf8ValidateSlice` が true を返す。

実機で未確認のこと:

- Windows の `std.process.Init` が実際に渡す `args.vector` に、不対サロゲートを含むコマンドラインが入ったときの `toSlice` の結果。ソースの経路と、上の単体テストが示す変換の結果から導いたものである。Windows 実機では実行していない。
- 環境変数の経路(`putWindowsBlock`)の実行。ソースの読解だけである。

このプロジェクトの扱い:

- 妥当な UTF-8 であることを、引数や環境変数の値から Scheme の文字列を作る前に `utf8ValidateSlice` で検査する。この検査は WTF-8 の不対サロゲートを拒否する。自前で条件を列挙しない([platform-and-web.md](platform-and-web.md))。
- 引数が Scheme の文字列になる経路は、`command-line` が入る段階5まで無い。検査を足す位置はその段階で決める。経緯は [plans/0006-slice-1h-strings-chars-vectors.md](../plans/0006-slice-1h-strings-chars-vectors.md) にある。

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
- モジュールの非ルートファイルの `test` ブロックは、ルートから参照されない限り1件も実行されない。`pub const reader = @import("reader.zig");` と書くだけでは足りない。実機で、必ず失敗するテストを `reader.zig` に置いても `2/2 tests passed` で exit 0 になることを確認した。`std.testing.refAllDecls(@This())` を呼ぶ `test` ブロックを置くと実行される。
- `std.testing.refAllDeclsRecursive` は 0.17.0 に存在しない。`refAllDecls` は1段しか辿らないので、他の `.zig` を `@import` するファイルすべてに置く。各階層に置いた場合に入れ子のディレクトリのテストまで実行されることを確認した。
- `wasm32-freestanding` を対象とするモジュールに `addTest` を作ってはならない。テストランナーが freestanding で成立せず、`posix.system` に `getrandom` や `IOV_MAX` や `STDIN_FILENO` が無いというコンパイルエラーになる。
- `b.addRunArtifact` の Run step の作業ディレクトリは `zig build` を起動したディレクトリであり、ビルドルートではない。リポジトリ内のファイルを相対パスで読むツールには `run.setCwd(b.path("."))` を設定する。
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

// `zig build wasm` で呼べるようにする。install しただけでは step は作られない
const wasm_step = b.step("wasm", "WASM をビルドする");
wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);
```

`b.installArtifact` は既定の step に紐づけるだけで、名前付きの step は作らない。`AGENTS.md` の検証コマンド表の `zig build <名前>` の形のコマンドは、`build` を除いてすべて `b.step` で作る必要がある。一覧をここに複製せず表を参照する。作り忘れると `error: no such step: wasm` のようになる(実機で確認した)。

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
    .paths = .{ "build.zig", "build.zig.zon", ".zigversion", "src", "tools", "tests", "LICENSE", "README.md" },
}
```

`.paths` の8エントリの根拠は次のとおりである。この一覧が正であり、`build.zig.zon` のコメントはここを参照する。

| エントリ | 根拠 |
| --- | --- |
| `build.zig`・`build.zig.zon` | ビルドそのもの |
| `.zigversion` | `build.zig` が `@embedFile(".zigversion")` で読む。欠けると依存パッケージとして取得されたときにビルドが失敗する |
| `src`・`tools` | 実装と検証プログラム |
| `tests` | 段階0の `zig build check-docs` が `tests/r7rs-required/*.txt` のハッシュ・ライブラリ数・識別子数を照合する。退避すると不合格になる(件数は `zig build check-docs` を実行して確かめる)。段階3の `zig build report` と段階6の `test-conformance` も読む |
| `LICENSE` | 許諾の条件がパッケージとともに届くようにする([ADR-0022](../adr/0022-unlicensed-proprietary.md))。欠けても機械は何も報告しない |
| `README.md` | 取得した側の入口。欠けても機械は何も報告しない |

`lib` は段階2で Scheme のソースを置いたときに加える。存在しないパスを先に書くと、何が必要で何が未着手かが読めなくなる。

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

版数の記述を2種に分け、扱いを変える。混ぜると更新のたびに取り残しが出る。

第1種は「現在固定しているバージョンはこれである」という宣言である。正は `.zigversion` のみとする。機械が読む必要がある `build.zig.zon` の `minimum_zig_version` と `.github/workflows/*.yml` は値を複製するが、`.zigversion` と一致することを `tools/check-docs` が検査する。README、ロードマップ、オンボーディングの前提表、SOW には宣言を書かず、`.zigversion` を参照する。

版の強制は `build.zig` が行う。`.zigversion` を `@embedFile` で読み、`builtin.zig_version` と完全一致しなければ診断を出して止める。

この強制には限界がある。`build.zig` がコンパイルされて実行されて初めて走るので、`std.zon.parse` や `std.process.Init` のような 0.17.0 固有の API が無い版では、configure 段のコンパイルが先に失敗して診断は出ない。利用者が見るのは標準ライブラリのエラーである。固定を外れた版を使っていることは伝わるが、原因が版であることは伝わらない。`comptime` の `@compileError` に移せば先に出せるが、`@embedFile` と `SemanticVersion.parse` を comptime で回す必要があり、段階0では採らない。`build.zig.zon` の `minimum_zig_version` にバージョン検査を期待してはならない。Zig 0.17.0 では検査されないことを実機で確認した。`minimum_zig_version = "0.99.0"` のまま `zig build` と `zig build test` が警告も出さずに exit 0 になる。`lib/compiler/` に `builtin.zig_version` との比較は存在しない。

第2種は「このバージョンで確認した」「このバージョンの API はこうである」という検証と仕様の記録である。本ドキュメント、ADR、設計ドキュメントの実機確認の記述がこれにあたる。版数を書く。これは履歴であって、バージョンを上げたときに自動で書き換える対象ではない。新しいバージョンで再確認したら、確認した版を併記するか記述を更新する。

`tools/check-docs` が版について検査するのは第1種の3箇所の一致、すなわち `.zigversion` と `build.zig.zon` と CI のワークフローだけである。

版数の宣言が散文に現れないことは機械検査にしない。実際に走らせると偽陽性と偽陰性が同時に出る。オンボーディングには `[0.17.0 の言語リファレンス](https://ziglang.org/documentation/0.17.0/)` という参照の URL があり、宣言ではないのに一致する。同じファイルの落とし穴の表には `0.17 では std.Io.Dir.cwd()` と書かれており、版を上げたときに古くなる記述なのに `0.17.0` には一致しない。宣言と参照と確認の記録を文字列で区別できない。下の更新手順の段で人手で確認する。

`tools/check-docs` が版以外に何を検査するかは [plans/0002-phase0-scaffolding.md](../plans/0002-phase0-scaffolding.md) の表が正である。ここに複製しない。

バージョンを上げるときは次の順で行う。

1. 新バージョンのリリースノートを読み、本ドキュメントの対応表に差分を追記する。
2. `.zigversion`、`build.zig.zon` の `minimum_zig_version`、CI のワークフローを同時に更新する。
3. `AGENTS.md` の検証コマンド表のうち、その時点の段階で使えるものをすべて通す。ここにコマンド名を列挙しない。列挙すると、段階が進んで増えた検証を飛ばす。std の API 変更で最初に壊れるのは後から増えたものである。
4. 本ドキュメントの表題と「前提」のバージョン表記を更新し、確認済みと未確認の印を見直す。新しい ADR を書いて ADR-0001 を非推奨にする。
5. `tools/check-docs` を走らせ、第1種の3箇所が一致していることを確認する。あわせて README・ロードマップ・オンボーディングの前提表・SOW に版数の宣言が入っていないことを目で確認する。機械検査の対象ではない。
6. 第2種の記述を `grep` で洗い出し、1件ずつ再確認が必要かを判断する。機械検査の対象外なのでこの段を飛ばさない。

これらを1つの PR で行い、バージョン更新だけのコミットに分ける。
