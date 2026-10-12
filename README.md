# sucheme-zig

sucheme-zig は、Zig で実装された R7RS-small 準拠を目標とする Scheme インタプリタです。衛生的マクロ、完全な継続、適切な末尾再帰、完全な数値塔までの準拠を目指します。

単体の実行ファイルと、WebAssembly を通じてブラウザ上で動くモジュールの両方を、同一のコアから生成することを目指しています。現在の到達点は [docs/roadmap.md](docs/roadmap.md) の「現在地」にあります。

名前はリポジトリオーナーに由来しています(`scheme` の打ち間違いではありません)。

## 状態

設計フェーズが完了し、実装は段階1(通しで動く最小の縦切り)に入っています。`zig build run` で REPL が動き、Scheme の式を評価できます。どこまで動くかは [docs/roadmap.md](docs/roadmap.md) の「現在地」が正です。

進捗の単一のソースは [docs/roadmap.md](docs/roadmap.md) です。現在の段階、最新リリース、段階ごとのチェックリストはそこにあります。R7RS の必須識別子のうちインタプリタが束縛しているものの表(段階1の最小版の準拠マトリクス)は [docs/status/](docs/status/) にあります。固定している Zig のバージョンは `.zigversion` が正です。

同じ数値を README にも書くと必ず食い違うため、ここには転記しません。

## 対応プラットフォーム

| プラットフォーム | ビルド | 自動テストによる動作保証 | そろう段階 |
| --- | --- | --- | --- |
| Linux (x86_64) | あり | あり | 0 |
| Windows (x86_64) | あり | あり | 0 |
| Linux (aarch64) | あり(クロスコンパイル) | なし | 0 |
| Windows (aarch64) | あり(クロスコンパイル) | なし | 0 |
| macOS (x86_64, aarch64) | あり(クロスコンパイル) | なし | 0 |
| WebAssembly | 段階1 | 段階1(Node.js 上でのエクスポート呼び出し) | 1 |

クロスコンパイルは `zig build -Dtarget=<ターゲット>` で今できます。`zig build dist` は、リリース成果物のターゲットすべての実行ファイルを `zig-out/dist/<ターゲット>/` に作り、`python3 tools/release/package.py` がそこからアーカイブと `SHA256SUMS` を作ります([ADR-0034](docs/adr/0034-release-shape.md))。タグの push で下書きのリリースを作るワークフロー(`release.yml`)があります。段階1から用意する残りは、リリースの公開と成果物の配布です。WebAssembly のビルドは段階1からです。進捗は [docs/roadmap.md](docs/roadmap.md) で確認してください。

自動テストを実行しているのは `ubuntu-latest` と `windows-latest` のランナー、すなわち x86_64 の Linux と Windows です。aarch64 と macOS は自動テストの対象にしません([ADR-0010](docs/adr/0010-ci-cd-and-release-strategy.md)、aarch64 は [ADR-0033](docs/adr/0033-aarch64-built-but-not-tested.md))。

macOS は GitHub Actions の課金単位が他の10倍であるためです。署名と公証も行いません。

aarch64 はランナー自体は使えます。段階1の見直しで、対象に加えないと決めました([ADR-0033](docs/adr/0033-aarch64-built-but-not-tested.md))。aarch64 では、ビルドが成功することを手元で確かめただけで、実行はしていません。CI でのビルドは、`zig build dist` を `full.yml` が PR を ready にしたときと `main` への push で走らせます(全コミットでは走りません)。v0.1.0 以降のリリースで配る aarch64 の Linux と Windows の実行ファイルは、実行して確かめていないものです。実行して確かめる仕組みは、実行環境が要ると分かった時点で足します。

WebAssembly の自動テストは Node.js 上でエクスポートを呼び出す往復テストです。ブラウザ自動化は行わないため、ブラウザ固有の問題は検出されません。

これらの環境で問題が出た場合は issue でお知らせください。リポジトリは private なので([ADR-0020](docs/adr/0020-repository-visibility-private.md))、issue とリリース成果物を扱えるのはアクセス権のある方だけです。

リリース成果物のターゲットは [ADR-0010](docs/adr/0010-ci-cd-and-release-strategy.md) が定めます。WebAssembly は配置しません。PR ごとに CI が成果物(`sucheme-web`)を上げるので、展開してローカルで開いて試す形にします。配置は段階8です([ADR-0021](docs/adr/0021-no-github-pages-defer-hosting.md))。リリースの成果物には、Web UI を `sucheme-web-v<版>.zip` として別に含める予定です(`zig build dist` と `tools/release/package.py` が組み立て、タグの push で動く `release.yml` が下書きのリリースを作りますが、まだタグを打っていないので、リリースはありません)。各アーカイブには、第三者の表示 `THIRD-PARTY-NOTICES.txt` が入ります。

## 特徴として目指すもの

- R7RS-small の16ライブラリすべての実装
- 衛生的マクロ(`syntax-rules`)、多重起動可能な完全な継続、適切な末尾再帰
- 完全な数値塔(多倍長整数、有理数、浮動小数点数、複素数)と Unicode 対応
- 複数行編集と Emacs バインディングを備えた REPL
- ブラウザ上で動く Web UI
- 依存パッケージを持たない構成(Zig 標準ライブラリのみ)

## ドキュメント

| 文書 | 内容 |
| --- | --- |
| [docs/onboarding.md](docs/onboarding.md) | 開発に参加するときの入口。環境の整え方とリポジトリの歩き方 |
| [docs/roadmap.md](docs/roadmap.md) | 段階、完了条件、現在地 |
| [docs/plans/0001-sow.md](docs/plans/0001-sow.md) | 作業範囲、成果物、進め方、リスク |
| [docs/design/](docs/design/) | アーキテクチャと各領域の設計 |
| [docs/adr/](docs/adr/) | 技術選択と設計判断の記録 |
| [docs/status/](docs/status/) | R7RS 準拠マトリクス(生成物。段階1の最小版) |

設計の中心となる判断は次の3つです。評価器は明示的な継続を持つ CEK 機械とし([ADR-0004](docs/adr/0004-cek-machine-evaluator.md))、GC は非移動型の精密マーク・スイープとし([ADR-0003](docs/adr/0003-precise-mark-sweep-gc.md))、コア言語で表現できるものは Scheme で書きます([ADR-0006](docs/adr/0006-library-system-and-scheme-level-stdlib.md))。いずれも WebAssembly を一級の対象とする制約から導かれています。

## ライセンス

ライセンスを付与していません。UNLICENSED です([ADR-0022](docs/adr/0022-unlicensed-proprietary.md))。全権利保留で、権利者以外による使用・複製・改変・再配布を許諾していません。詳細は [LICENSE](LICENSE) を参照してください。

この宣言が適用されるのは本変更以後の版です。2026-10-04 から 2026-10-06 までリポジトリは public で MIT でした。MIT に終了条項はないので、その期間に得た複製の条件は変わりません。

名前の似た Unlicense(パブリックドメインへの献呈)とは逆の意味です。取り違えないでください。

`tests/vendor/` 以下に置く外部由来のテストスイートは、それぞれの元のライセンス(BSD 3条項)に従います。

`tools/extract-r7rs-required/appendix-a.html` は R7RS の付録A の逐語コピーです。R7RS 自身が全文または一部の複製を許諾しています。出典と許諾の根拠は [tools/extract-r7rs-required/SOURCE.md](tools/extract-r7rs-required/SOURCE.md) にあります。

`tests/r7rs-required/*.txt` はそのコピーから抽出した R7RS の内容なので、同じ許諾に依拠します。各ファイルが2行目で出典を名乗っています。

`docs/` 以下には R7RS とその他の仕様の逐語引用が含まれます。引用として用いているもので、上の宣言の対象ではありません。

上の宣言は sucheme-zig 自身の成果物に適用されるもので、この節で挙げた第三者由来のものには適用されません。対象外の一覧は [LICENSE](LICENSE) が正です。

## AIコーディングエージェントへの指示

[AGENTS.md](AGENTS.md) が単一のソースです。GitHub Copilot、Claude Code、Codex の共有スキルは [.agents/skills/](.agents/skills/) にあります。
