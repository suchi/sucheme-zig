# 5 ライブラリ

sucheme は、ライブラリのシステムを持っています。`import` で、必要なライブラリの名前を書きます。

## 標準のライブラリ

次のライブラリは `import` できます。どれも実行ファイルに埋め込んであり、別のファイルは要りません。

- `(scheme base)`、`(scheme case-lambda)`、`(scheme char)`、`(scheme complex)`、`(scheme cxr)`、`(scheme eval)`、`(scheme file)`、`(scheme inexact)`、`(scheme lazy)`、`(scheme load)`、`(scheme process-context)`、`(scheme r5rs)`、`(scheme read)`、`(scheme repl)`、`(scheme time)`、`(scheme write)`

どのライブラリがどの識別子を輸出するかは、[準拠マトリクス](../../status/conformance.md)にあります。マトリクスは生成物で、識別子ごとに、`import` したときに束縛されているかが分かります。

REPL とファイルの最初の環境は、`(scheme base)` だけです。ほかのライブラリの名前は、使う前に `import` します。

```scheme fresh
(import (scheme inexact))
(exact (floor (sqrt 17)))
```

```output
4
```

知らない名前を `import` すると、誤りです。

```scheme fresh
(import (scheme nosuch))
```

```output
error: 1:1: unknown library: (scheme nosuch)
```

1つの `import` に読めないライブラリが混じると、その `import` の全体が誤りになります。

### 内部のライブラリ

`(sucheme core)` は、利用者が `import` すると誤りです。

```scheme fresh
(import (sucheme core))
```

```output
error: 1:1: bad import: the library (sucheme core) is only for the standard libraries the executable carries
```

`(sucheme derived)`、`(sucheme procedures)`、`(sucheme test-results)`、`(chibi test)` は `import` できますが、標準ライブラリと準拠スイートの部品で、名前と中身が予告なく変わります。使わないでください。

## 自分のライブラリ

`define-library` で書いたライブラリは、ファイルに置いて、探索のディレクトリ(探索ルート)から `import` で読ませます。ライブラリ名 `(mylib greet)` は、探索ルートの下の `mylib/greet.sld` から読まれます。名前の各要素がディレクトリになり、最後の要素に `.sld` を付けたものがファイル名です。

```text
(define-library (mylib greet)
  (import (scheme base) (scheme write))
  (export greet)
  (begin
    (define (greet name)
      (display "Hello, ")
      (display name)
      (newline))))
```

これは `lib/mylib/greet.sld` に置いてあります。このライブラリを使うプログラム `use-greet.scm` は、`(import (scheme base) (mylib greet))` で始まり、`(greet "sucheme")` を呼びます。

探索ルートは、作業ディレクトリが先頭で、`-I <dir>` で足したディレクトリが書いた順に続きます。`lib/` を `-I` で足さないと、作業ディレクトリの下に `mylib/greet.sld` が無いので、見つかりません。

```console
$ sucheme use-greet.scm
error: use-greet.scm:1:1: unknown library: (mylib greet)
[exit 1]
```

```console
$ sucheme -I lib use-greet.scm
Hello, sucheme
```

`-I` は、何度でも書けます。同じ名前のファイルが複数のルートにあるときは、先のルートのものが使われます。`-I` の次の引数は、`-` で始まっていても、ディレクトリの名前です。開けないディレクトリは、何も持たないものとして読み飛ばします。環境変数は読みません。ルートの下のシンボリックリンクは辿りません(ルートそのものはリンクでもかまいません)。

`include` と `load` も、同じ探索ルートの規則でファイルを開きます。ただし、プログラムが `open-input-file` などで開くファイルは、探索ルートに制約されません。詳細は [src/main.zig](../../../src/main.zig) の doc コメントにあります。
