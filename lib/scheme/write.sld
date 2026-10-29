;; R7RS の `(scheme write)`。スライス 5i では `display` だけを輸出する。`write`、`write-shared`、
;; `write-simple` はスライス 5j が足す(docs/plans/0019-phase5-ports-and-io.md)。
(define-library (scheme write)
  (import (sucheme core))
  (export display))
