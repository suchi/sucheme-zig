# 使われない補助ディレクトリがある文書

`zig build test` が、この上のディレクトリを作業ディレクトリにして `check-examples` を走らせ、終了コード 1 で終わることを確かめる。ブロックと、プログラムの `.scm` と `.out` は正しく、`hello.files/` だけが、どの `.args` の引数からも `@files/` で指されない(`build.zig` を参照)。

```scheme
(+ 1 2)
```

```output
3
```
