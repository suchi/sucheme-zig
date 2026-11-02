;; R7RS 付録A の `(scheme r5rs)`。R5RS の識別子を、R7RS のライブラリから再輸出する(スライス 5q、
;; docs/plans/0019-phase5-ports-and-io.md)。名前の並びは `tests/r7rs-required/r5rs.txt` の順である。
;; R5RS にだけある4つは、本体で定義する。`exact->inexact` と `inexact->exact` は R7RS の `inexact` と
;; `exact` の古い名前である(R7RS 6.2.6)。`scheme-report-environment` と `null-environment` は R7RS 6.12
;; の手続きで、版 5 の環境の指定子を返す。
(define-library (scheme r5rs)
  (import (scheme base) (scheme char) (scheme complex) (scheme cxr) (scheme eval)
          (scheme file) (scheme inexact) (scheme lazy) (scheme load) (scheme read) (scheme repl)
          (scheme write))
  (export * + - ... / < <= = => > >= _ abs acos and angle append apply asin assoc assq assv atan
          begin boolean? caaaar caaadr caaar caadar caaddr caadr caar cadaar cadadr cadar caddar
          cadddr caddr cadr call-with-current-continuation call-with-input-file
          call-with-output-file call-with-values car case cdaaar cdaadr cdaar cdadar cdaddr cdadr
          cdar cddaar cddadr cddar cdddar cddddr cdddr cddr cdr ceiling char->integer
          char-alphabetic? char-ci<=? char-ci<? char-ci=? char-ci>=? char-ci>? char-downcase
          char-lower-case? char-numeric? char-ready? char-upcase char-upper-case? char-whitespace?
          char<=? char<? char=? char>=? char>? char? close-input-port close-output-port complex?
          cond cons cos current-input-port current-output-port define define-syntax delay
          denominator display do dynamic-wind else eof-object? eq? equal? eqv? eval even?
          exact->inexact exact? exp expt floor for-each force gcd if imag-part inexact->exact
          inexact? input-port? integer->char integer? interaction-environment lambda lcm length let
          let* let-syntax letrec letrec-syntax list list->string list->vector list-ref list-tail
          list? load log magnitude make-polar make-rectangular make-string make-vector map max
          member memq memv min modulo negative? newline not null-environment null? number->string
          number? numerator odd? open-input-file open-output-file or output-port? pair? peek-char
          positive? procedure? quasiquote quote quotient rational? rationalize read read-char
          real-part real? remainder reverse round scheme-report-environment set! set-car! set-cdr!
          sin sqrt string string->list string->number string->symbol string-append string-ci<=?
          string-ci<? string-ci=? string-ci>=? string-ci>? string-copy string-fill! string-length
          string-ref string-set! string<=? string<? string=? string>=? string>? string? substring
          symbol->string symbol? syntax-rules tan truncate values vector vector->list vector-fill!
          vector-length vector-ref vector-set! vector? with-input-from-file with-output-to-file
          write write-char zero?)
  (begin
    (define exact->inexact inexact)
    (define inexact->exact exact)
    ;; R7RS 6.12 は、版 5 のときの環境だけを定め、ほかの版は処理系に任せる。5 のほかは誤りにする。
    (define (check-version who version)
      (unless (eqv? version 5)
        (error (string-append "unsupported version in " who) version)))
    ;; 呼ぶたびに新しい指定子を作る(`environment` と同じ)。どちらも変更できない。
    ;; Why: R7RS 付録A の `(scheme r5rs)` の一覧は `unquote` と `unquote-splicing` を含まない。
    ;; 束縛が無いと、`quasiquote` の中の `,x` が補助構文として認められず、`(unquote x)` という
    ;; データのまま残る。R5RS の環境では準引用が働くべきなので、`(scheme base)` から足す。
    (define (scheme-report-environment version)
      (check-version "scheme-report-environment" version)
      (environment '(scheme r5rs) '(only (scheme base) unquote unquote-splicing)))
    ;; R5RS の構文キーワードの束縛だけを持つ環境(R7RS 6.12)。
    (define (null-environment version)
      (check-version "null-environment" version)
      (environment '(only (scheme r5rs)
                          quote lambda if set! cond case and or let let* letrec begin do delay
                          quasiquote define define-syntax let-syntax letrec-syntax syntax-rules
                          else => ... _)
                   '(only (scheme base) unquote unquote-splicing)))))
