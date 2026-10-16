;; Scheme で書く標準の手続きのライブラリ。手続きは procedures.scm に書く
;; (docs/design/frontend.md の「標準ライブラリの起動順序」)。
(define-library (sucheme procedures)
  (import (sucheme core))
  (export append reverse list-tail list-ref list-set! list-copy make-list
          memq memv member assq assv assoc map for-each
          caar cadr cdar cddr boolean=?)
  (include "procedures.scm"))
