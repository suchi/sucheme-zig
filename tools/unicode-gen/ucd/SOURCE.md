# UCD ファイルの出典

`src/unicode/tables.zig` を生成するための入力。手で編集しない。

| 項目 | 値 |
| --- | --- |
| 取得元 | <https://www.unicode.org/Public/18.0.0/ucd/> |
| Unicode の版 | 18.0.0 |
| 取得日 | 2026-10-28 (JST) |
| 公開日の根拠 | 取得元のディレクトリ一覧の更新日は 2026-09-01。これはタグのコミット日時ではなく、UCD にその相当物はない。一覧を見た日時は 2026-10-28 08:46 JST(ファイルの取得は 08:52 JST)。`18.0.0/ReadMe.txt` に日付は書かれていない |
| 生成器 | [main.zig](../main.zig) |
| ハッシュ | [SHA256SUMS](SHA256SUMS)(`sha256sum` 形式。生成器が読み込み前に照合する) |
| ライセンス | Unicode License V3([LICENSE.txt](LICENSE.txt)) |

## ファイル

| ファイル | サイズ(バイト) | ファイル冒頭の日付 |
| --- | --- | --- |
| `UnicodeData.txt` | 2,243,593 | - |
| `DerivedCoreProperties.txt` | 1,159,889 | 2026-08-07 |
| `PropList.txt` | 149,040 | 2026-08-07 |
| `SpecialCasing.txt` | 17,422 | 2026-05-19 |
| `CaseFolding.txt` | 88,776 | 2026-02-03 |

ファイルは取得したままで、改変していない。冒頭の著作権と許諾の通知はファイル内に残っている。ライセンスの条件は、通知を複製に添えることである(原文: <https://www.unicode.org/license.txt>)。

## 更新の手順

版を上げるときは、新しい版の同じ5ファイルを置き、`sha256sum UnicodeData.txt DerivedCoreProperties.txt PropList.txt SpecialCasing.txt CaseFolding.txt > SHA256SUMS` で記録を作り直し、`zig build generate-unicode` で `src/unicode/tables.zig` を作り直して、差分をレビューする。公開から7日以上たった版を選び、公開日の根拠を上の表に書く。

ネットワークから取得せずリポジトリに置くのは、生成をネットワークに依存させず、生成物の同期の検査を CI で走らせるためである([numerics-and-unicode.md](../../../docs/design/numerics-and-unicode.md))。
