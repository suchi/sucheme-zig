;; R7RS の `(scheme process-context)`。どれも `(sucheme core)` のプリミティブである(スライス 5m、
;; docs/plans/0019-phase5-ports-and-io.md)。`exit` と `emergency-exit` は機械操作プリミティブで、
;; ほかは純粋プリミティブである(src/prim/process.zig)。
(define-library (scheme process-context)
  (import (sucheme core))
  (export command-line emergency-exit exit get-environment-variable get-environment-variables))
