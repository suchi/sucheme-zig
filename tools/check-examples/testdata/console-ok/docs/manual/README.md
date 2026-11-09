# console-ok

実行ファイルで `console` のブロックを走らせる検査の、通る側の入力です。`console-differs` と同じ形です。

```scheme
(+ 1 2)
```

```output
3
```

```console
$ sucheme hello.scm
Hello
$ sucheme nothing.scm
error: cannot read nothing.scm: FileNotFound
[exit 66]
```
