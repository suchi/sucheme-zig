;; R7RS の `(scheme inexact)`。12個の識別子はすべて `(sucheme core)` のプリミティブ
;; (`src/prim/inexact.zig`)である。名前の並びは `tests/r7rs-required/inexact.txt` の順である。
(define-library (scheme inexact)
  (import (sucheme core))
  (export acos asin atan cos exp finite? infinite? log nan? sin sqrt tan))
