;; 派生構文のライブラリ。派生構文は derived.scm に `syntax-rules` で書く
;; (docs/design/frontend.md の「標準ライブラリの起動順序」)。
;; `case` と `quasiquote` の展開が、`(sucheme procedures)` の `memv` と `append` を
;; 使うので、それを取り込む。`(sucheme procedures)` は派生構文を使わずに書く。
(define-library (sucheme derived)
  (import (sucheme core) (sucheme procedures))
  (export cond case and or when unless let let* letrec letrec* do quasiquote)
  (include "derived.scm"))
