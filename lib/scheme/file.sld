;; R7RS の `(scheme file)`。開く手続きと `file-exists?` `delete-file` は `(sucheme core)` の
;; プリミティブで、`call-with-*` と `with-*` は `(sucheme procedures)` が持つ(スライス 5k、
;; docs/plans/0019-phase5-ports-and-io.md)。
(define-library (scheme file)
  (import (sucheme core) (sucheme procedures))
  (export call-with-input-file call-with-output-file
          delete-file file-exists?
          open-binary-input-file open-binary-output-file
          open-input-file open-output-file
          with-input-from-file with-output-to-file))
