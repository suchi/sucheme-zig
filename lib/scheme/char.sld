;; R7RS の `(scheme char)`。22個の識別子はすべて `(sucheme core)` のプリミティブ
;; (`src/prim/char.zig` と `src/prim/string_case.zig`)である。名前の並びは
;; `tests/r7rs-required/char.txt` の順である。
(define-library (scheme char)
  (import (sucheme core))
  (export char-alphabetic? char-ci<=? char-ci<? char-ci=? char-ci>=? char-ci>?
          char-downcase char-foldcase char-lower-case? char-numeric? char-upcase
          char-upper-case? char-whitespace? digit-value
          string-ci<=? string-ci<? string-ci=? string-ci>=? string-ci>?
          string-downcase string-foldcase string-upcase))
