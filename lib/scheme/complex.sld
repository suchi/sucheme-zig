;; R7RS の `(scheme complex)`。6個の識別子はすべて `(sucheme core)` のプリミティブ
;; (`src/prim/complex.zig`)である。名前の並びは `tests/r7rs-required/complex.txt` の順である。
(define-library (scheme complex)
  (import (sucheme core))
  (export angle imag-part magnitude make-polar make-rectangular real-part))
