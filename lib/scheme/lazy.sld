;; R7RS の `(scheme lazy)`。`delay` と `delay-force` は `(sucheme derived)` が、
;; `force` と `make-promise` と `promise?` は `(sucheme core)` が持つ。
(define-library (scheme lazy)
  (import (sucheme core) (sucheme derived))
  (export delay delay-force force make-promise promise?))
