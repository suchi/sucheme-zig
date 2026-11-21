<p align="center">
  <img alt="sucheme" src="docs/images/logo.svg" width="360">
</p>

# sucheme-zig

sucheme-zig は、Zig で実装された R7RS-small 準拠の Scheme インタプリタです。単体の実行ファイルと、WebAssembly を通じてブラウザ上で動くモジュールを、同一のコアから生成します。

## 状態

開発中です。どの段階まで実装されているかは、[docs/roadmap.md](docs/roadmap.md) の「現在地」が正です。

## 使い方

リリースの成果物は、GitHub の Releases から取得できます。各アーカイブには、実行ファイルと第三者の表示 `THIRD-PARTY-NOTICES.txt` が入ります。最新のリリースは [docs/roadmap.md](docs/roadmap.md) の「現在地」から辿れます。

ソースからは、`.zigversion` が指す版の Zig で、次のようにビルドして実行します。

```sh
zig build
zig build run
```

引数なしの `zig build run` は、標準入力を読む REPL になります。

## 対応プラットフォーム

| プラットフォーム | ビルド | 自動テストによる動作保証 |
| --- | --- | --- |
| Linux (x86_64) | あり | あり |
| Windows (x86_64) | あり | あり |
| Linux (aarch64) | あり(クロスコンパイル) | なし |
| Windows (aarch64) | あり(クロスコンパイル) | なし |
| macOS (x86_64, aarch64) | あり(クロスコンパイル) | なし |
| WebAssembly | あり | あり(Node.js 上でのエクスポート呼び出し) |

自動テストの範囲の根拠は [ADR-0010](docs/adr/0010-ci-cd-and-release-strategy.md) と [ADR-0033](docs/adr/0033-aarch64-built-but-not-tested.md) にあります。不具合は issue でお知らせください。

## ドキュメント

| 文書 | 内容 |
| --- | --- |
| [docs/manual/](docs/manual/README.md) | 使う人のための文書(チュートリアル、ユーザーズガイド、リファレンス、プログラム集) |
| [docs/onboarding.md](docs/onboarding.md) | 開発に参加するときの入口 |
| [docs/roadmap.md](docs/roadmap.md) | 段階、完了条件、現在地 |
| [docs/design/](docs/design/) | アーキテクチャと各領域の設計 |
| [docs/adr/](docs/adr/) | 技術選択と設計判断の記録 |

## ライセンス

MIT ライセンスです。条文は [LICENSE](LICENSE) を参照してください。第三者に由来するもの(R7RS の付録Aの複製と、そこから抽出したもの、取り込んだ準拠スイート、Unicode の表のもとになったデータ)は、この宣言の対象外で、それぞれの条件に従います。対象外の一覧は [LICENSE](LICENSE) が正です。

## 開発者向け

開発の進め方は [AGENTS.md](AGENTS.md) にまとめています。

## 免責

このソフトウェアは、AI コーディングエージェントとの協働(Agentic Coding)で作られています。コード全体を、人間が一行ずつ把握しきれていない部分があります。そのため、動作や品質は保証できず、利用の結果についても責任を負えません。この点は MIT ライセンスの条文(無保証であること、責任を負わないこと)に従うものであり、ここでも改めて明示します。ご利用は、この前提をご理解のうえでお願いします。
