;; R7RS の `(scheme write)`。`display` はスライス 5i が、`write`、`write-shared`、`write-simple` は
;; スライス 5j が足した(docs/plans/0019-phase5-ports-and-io.md)。
(define-library (scheme write)
  (import (sucheme core))
  (export display write write-shared write-simple))
