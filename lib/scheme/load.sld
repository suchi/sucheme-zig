;; R7RS の `(scheme load)`。`load` は `(sucheme core)` のプリミティブで、ファイルの形式を1つずつ
;; 展開して走らせる(スライス 5p、src/prim/eval.zig)。
(define-library (scheme load)
  (import (sucheme core))
  (export load))
