;; R7RS の `(scheme base)`。必須識別子のうち、`(sucheme core)` と `(sucheme derived)` と
;; `(sucheme procedures)` に実装があるものだけを再エクスポートする。実装が無いものは、ここに
;; 書かない(準拠マトリクスが未実装として表す。数値塔を要るものは段階4、ポートは段階5が足す)。
;; 独自の識別子は入れない(R7RS 5.6.1)。`%` で始まる内部用の名前は、`(sucheme core)` に
;; 残し、ここには入れない。名前の並びは `tests/r7rs-required/base.txt` の順である。
(define-library (scheme base)
  (import (sucheme core) (sucheme derived) (sucheme procedures))
  (export * + - ... / < <= = => > >= _ abs and append apply assoc assq assv begin boolean=?
          boolean? bytevector bytevector-append bytevector-copy bytevector-copy!
          bytevector-length bytevector-u8-ref bytevector-u8-set! bytevector? caar cadr
          call-with-current-continuation call-with-values call/cc car case cdar cddr cdr
          ceiling char->integer char<=? char<? char=? char>=? char>? char? complex? cond
          cond-expand cons define define-record-type define-syntax define-values denominator
          do dynamic-wind else eof-object eof-object? eq? equal? eqv? error
          error-object-irritants error-object-message error-object? even? exact
          exact-integer? exact? features file-error? floor floor-quotient floor-remainder
          floor/ for-each gcd guard if include include-ci inexact inexact? integer->char
          integer? lambda lcm length let let* let*-values let-syntax let-values letrec
          letrec* letrec-syntax list list->string list->vector list-copy list-ref list-set!
          list-tail list? make-bytevector make-list make-parameter make-string make-vector
          map max member memq memv min modulo negative? not null? number? numerator odd? or
          pair? parameterize positive? procedure? quasiquote quote quotient raise
          raise-continuable rational? read-error? real? remainder reverse round set!
          set-car! set-cdr! square string string->list string->symbol string->utf8
          string->vector string-append string-copy string-copy! string-fill! string-for-each
          string-length string-map string-ref string-set! string<=? string<? string=?
          string>=? string>? string? substring symbol->string symbol=? symbol? syntax-error
          syntax-rules truncate truncate-quotient truncate-remainder truncate/ unless
          unquote unquote-splicing utf8->string values vector vector->list vector->string
          vector-append vector-copy vector-copy! vector-fill! vector-for-each vector-length
          vector-map vector-ref vector-set! vector? when with-exception-handler zero?))
