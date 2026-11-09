# console-differs

実行ファイルで `console` のブロックを走らせる検査の、落ちる側の入力です。期待する出力が実際と違います。

```scheme
(+ 1 2)
```

```output
3
```

```console
$ sucheme hello.scm
Goodbye
$ sucheme nothing.scm
error: cannot read nothing.scm: FileNotFound
[exit 66]
```
