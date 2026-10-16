;; 派生構文のライブラリ。派生構文は derived.scm に `syntax-rules` で書く
;; (docs/design/frontend.md の「標準ライブラリの起動順序」)。
(define-library (sucheme derived)
  (import (sucheme core))
  (export when unless)
  (include "derived.scm"))
