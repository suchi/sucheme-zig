;; R7RS の `(scheme repl)`。`interaction-environment` は `(sucheme core)` のプリミティブで、REPL の
;; 最上位を指す環境の指定子を返す(スライス 5o、src/prim/eval.zig)。
(define-library (scheme repl)
  (import (sucheme core))
  (export interaction-environment))
