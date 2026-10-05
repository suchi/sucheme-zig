# 設計ドキュメント

sucheme-zig の設計フェーズ(手順1)の成果物。実装の前提となる構造・不変条件・検証済みの事実を記録する。

| ドキュメント | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 全体構成、モジュールマップ、データフロー、横断的な不変条件 |
| [runtime.md](runtime.md) | 値表現、GC、環境、CEK機械、継続、例外 |
| [frontend.md](frontend.md) | リーダ、マクロ展開器、syntax-rules、ライブラリシステム、コアIR |
| [numerics-and-unicode.md](numerics-and-unicode.md) | 数値塔、Unicode |
| [platform-and-web.md](platform-and-web.md) | プラットフォーム抽象、WebAssembly、Web UI |
| [zig-api-notes.md](zig-api-notes.md) | Zig 0.17.0 の実機検証済み API ノート |
| [r7rs-coverage.md](r7rs-coverage.md) | R7RS 要件の分解と準拠マトリクスの定義 |
| [open-questions.md](open-questions.md) | 実装時に決めることの一覧。未確定事項はここに1箇所だけ置く |

書く範囲の方針は [ADR-0018](../adr/0018-incremental-vertical-slices.md) にある。全体整合性に必要な構造は設計時に決め、1つのモジュールに閉じた詳細は実装時に決めて [open-questions.md](open-questions.md) に記録する。

決定そのものは [../adr/](../adr/) に、作業計画は [../plans/](../plans/) と [../roadmap.md](../roadmap.md) にある。
