# sucheme-zig

sucheme-zig は、Zig で実装された R7RS-small 準拠を目標とする Scheme インタプリタです。衛生的マクロ、完全な継続、適切な末尾再帰、完全な数値塔までの準拠を目指します。

単体の実行ファイルと、WebAssembly を通じてブラウザ上で動くモジュールの両方を、同一のコアから生成することを目指しています。現時点で動くのはビルドの足場だけで、Scheme の評価はまだできません。

名前はリポジトリオーナーに由来しています(`scheme` の打ち間違いではありません)。

## 状態

設計フェーズが完了し、実装の段階0(足場)まで進んでいます。`zig build` で実行ファイルができ、`--version` に答えます。Scheme の評価は段階1からです。

進捗の単一のソースは [docs/roadmap.md](docs/roadmap.md) です。現在の段階、最新リリース、段階ごとのチェックリストはそこにあります。R7RS 準拠の達成度は [docs/status/](docs/status/) にあります。固定している Zig のバージョンは `.zigversion` が正です。

同じ数値を README にも書くと必ず食い違うため、ここには転記しません。

## 対応プラットフォーム

| プラットフォーム | ビルド | 自動テストによる動作保証 | 到達した段階 |
| --- | --- | --- | --- |
| Linux (x86_64) | あり | あり | 0 |
| Windows (x86_64) | あり | あり | 0 |
| Linux (aarch64) | あり(クロスコンパイル) | なし | 0 |
| Windows (aarch64) | あり(クロスコンパイル) | なし | 0 |
| macOS (x86_64, aarch64) | あり(クロスコンパイル) | なし | 0 |
| WebAssembly | 目標 | 目標(Node.js 上でのエクスポート呼び出し) | 段階1 |

クロスコンパイルは `zig build -Dtarget=<ターゲット>` で今できます。段階1から用意するのはリリースのワークフローと成果物の配布です。WebAssembly のビルドは段階1からです。進捗は [docs/roadmap.md](docs/roadmap.md) で確認してください。

自動テストを実行しているのは `ubuntu-latest` と `windows-latest` のランナー、すなわち x86_64 の Linux と Windows です。aarch64 と macOS は自動テストの対象にしません。GitHub Actions の macOS ランナーの課金単位が他の10倍であるためです([ADR-0010](docs/adr/0010-ci-cd-and-release-strategy.md))。macOS の署名と公証も行いません。

WebAssembly の自動テストは Node.js 上でエクスポートを呼び出す往復テストです。ブラウザ自動化は行わないため、ブラウザ固有の問題は検出されません。

これらの環境で問題が出た場合は issue でお知らせください。リポジトリは private なので([ADR-0020](docs/adr/0020-repository-visibility-private.md))、issue とリリース成果物を扱えるのはアクセス権のある方だけです。

リリース成果物のターゲットは [ADR-0010](docs/adr/0010-ci-cd-and-release-strategy.md) が定めます。WebAssembly は配置しません。段階1から、CI の成果物として zip で添付し、ローカルで開いて試す形にします。配置は段階8です([ADR-0021](docs/adr/0021-no-github-pages-defer-hosting.md))。

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
| [docs/status/](docs/status/) | R7RS 準拠マトリクス(生成物) |

設計の中心となる判断は次の3つです。評価器は明示的な継続を持つ CEK 機械とし([ADR-0004](docs/adr/0004-cek-machine-evaluator.md))、GC は非移動型の精密マーク・スイープとし([ADR-0003](docs/adr/0003-precise-mark-sweep-gc.md))、コア言語で表現できるものは Scheme で書きます([ADR-0006](docs/adr/0006-library-system-and-scheme-level-stdlib.md))。いずれも WebAssembly を一級の対象とする制約から導かれています。

## ライセンス

MIT License です。詳細は [LICENSE](LICENSE) を参照してください。

`tests/vendor/` 以下に置く外部由来のテストスイートは、それぞれの元のライセンス(BSD 3条項)に従います。

`tools/extract-r7rs-required/appendix-a.html` は R7RS の付録A の逐語コピーです。R7RS 自身が全文または一部の複製を許諾しています。出典と許諾の根拠は [tools/extract-r7rs-required/SOURCE.md](tools/extract-r7rs-required/SOURCE.md) にあります。MIT License はこのファイルには適用されません。

## AIコーディングエージェントへの指示

[AGENTS.md](AGENTS.md) が単一のソースです。GitHub Copilot、Claude Code、Codex の共有スキルは [.agents/skills/](.agents/skills/) にあります。
