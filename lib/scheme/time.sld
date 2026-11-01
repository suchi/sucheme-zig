;; R7RS の `(scheme time)`。どれも `(sucheme core)` の純粋プリミティブである(スライス 5n、
;; docs/plans/0019-phase5-ports-and-io.md、src/prim/time.zig)。
(define-library (scheme time)
  (import (sucheme core))
  (export current-jiffy current-second jiffies-per-second))
