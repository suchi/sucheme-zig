# ADR-0047: 規模を試す層の単体テストは、既定で ReleaseSafe で走らせる

- ステータス: 採用
- 日付: 2026-10-24

## 背景

層2(`full.yml`)の slow tests のジョブは、CI で約 33 分かかり、そのうち `zig build test -Dslow=true` が約 11 分を占めていた。たとえば 2026-10-23 の `full.yml` の実行(run_number 219)では、この step は 13:28:37 UTC に始まり 13:40:33 UTC に終わった。[計画書 0017](../plans/0017-parallel-lanes.md) が記録した run_number 159 では約 5 分だった。差の理由は調べていない。単体テストは `-Doptimize` を付けないと Debug でビルドされる。規模を試すテスト(100万回の呼び出し、10万段の再帰)は、Debug では数倍遅い。`test-scheme` と `test-wasm` は、`build.zig` がすでに ReleaseSafe に固定している。

親のセッションの手元の測定(4 vCPU、2026-10-24)では、`zig build test -Dslow=true` の壁時計は、Debug で 558 秒、`-Doptimize=ReleaseSafe` で 166 秒だった。両者で、テスト名の集合と結果(全件が通る)は同じだった。

層2の時間を、検査を減らさずに縮める案は、計画書 0026(`docs/plans/0026-shorten-slow-tier.md`。suchi/sucheme-zig#193 で足す)にまとめた。この ADR は、そのうちの案1を、2026-10-24 に決めた決定として記録する。

## 決定

`-Dslow=true` を指定し、`-Doptimize` を指定しないときは、`build.zig` の最適化の既定を ReleaseSafe にする。

- `-Doptimize` を指定したときは、その値が優先する。
- `-Dslow=true` を指定しないときは、今までどおり `b.standardOptimizeOption` に従う(既定は Debug)。
- 既定は `build.zig` の `optimize` そのものに効く。`-Dslow=true` のときの単体テストのバイナリ、規模を試す実行ファイルの実行(`tests/cli-slow/`)、評価器のファジングのバイナリが ReleaseSafe になる。`test-scheme`、`test-wasm`、`dist` は、もともと固定の最適化を使うので変わらない。
- `-Dslow=true` のときは、`--release` の指定を読まない。このリポジトリのワークフローと文書は `--release` を使っていない。
- ワークフロー(`full.yml`)と、AGENTS.md の検証コマンド表の綴りは変えない。

選ばなかった案は次のとおりである。

- `full.yml` の行に `-Doptimize=ReleaseSafe` を足す案: `build.zig` の意味は変わらないが、ワークフローの変更と、検証コマンド表と `check-docs` の照合の変更が要る。
- Debug のまま走らせる案: 層2の単体テストに約 11 分かかったままになる。
- 単体テストのバイナリだけを ReleaseSafe にし、実行ファイルを Debug に残す案: `sucheme` のモジュールを、テスト用と実行ファイル用に分けて作る必要がある。規模を試す実行ファイルの実行は、Debug でも ReleaseSafe でも `SafeAllocator` と `smp_allocator` を同じように使う(`src/main.zig`)ので、分ける利点が小さい。

## 結果

- メリット:
  - 安全検査(境界、オーバーフロー、到達しないはずの分岐、アサーション)は残る。ReleaseSafe は安全検査を外さない。
  - 層2の3つのコマンドの最適化がそろう。
- デメリット・受け入れたトレードオフ:
  - Debug は `undefined` のメモリを 0xaa で埋めるが、ReleaseSafe は埋めない。未初期化のメモリを読む誤りは、規模を試すテストでは見えにくくなる。全コミットの `zig build test` は Debug のまま走り、規模を試すテストの縮小版を含むので、同じ論理の誤りはそこで見つかる見込みである。
  - `std.testing.allocator`(Zig 0.17.0 では `std.heap.SafeAllocator`)は、ReleaseSafe でも漏れを報告し、テストを失敗にする。二重の解放も止める。ただし、漏れた確保の場所のスタックトレースは空になる(2026-10-24 に、漏れと二重の解放を起こす使い捨てのテストで確かめた)。規模を試すテストで漏れが見つかったときは、`-Doptimize=Debug` を付けて走らせ直すと、確保の場所が出る。
  - `-Doptimize` を付けないときの意味が、`-Dslow` の有無で変わる。
  - `-Dslow=true` に `--release=fast` などを付けても、誤りにならずに黙って無視され、ReleaseSafe になる。
- 将来の見直し条件: 規模を試すテストでだけ見つかる未初期化のメモリの誤りが出たとき。`--release` を使う手順を足すとき。
