;; R7RS の `(scheme read)`。`read` は `(sucheme core)` のプリミティブである(スライス 5l、
;; docs/plans/0019-phase5-ports-and-io.md)。
(define-library (scheme read)
  (import (sucheme core))
  (export read))
