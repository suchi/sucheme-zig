;; R7RS の `(scheme eval)`。どれも `(sucheme core)` のプリミティブである(スライス 5o、
;; docs/plans/0019-phase5-ports-and-io.md、src/prim/eval.zig)。
(define-library (scheme eval)
  (import (sucheme core))
  (export environment eval))
