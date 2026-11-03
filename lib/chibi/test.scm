;; `(chibi test)` の本体。test.sld が include する。

;; `thunk` を呼び、値を返せば `(value v)`、条件が上がれば `(raised c)` を返す。
;; 条件はハンドラから脱出して受け取るので、`raise` も `raise-continuable` も、
;; 処理系が上げる誤りも、テストの外に出ない。
(define (test-outcome thunk)
  (call/cc
   (lambda (k)
     (with-exception-handler
      (lambda (c) (k (list 'raised c)))
      (lambda () (list 'value (thunk)))))))

;; 不正確な数の比較で許す相対の差。上流の `(chibi test)` の既定値と同じである
;; (docs/plans/0028-phase6-conformance.md の「確かめた事実」)。
(define test-epsilon 1e-5)

;; 実数 `x` と `y` が近いかを返す。差を、絶対値の大きいほうで割った比で測る。
;; 絶対値の小さいほうが0なら、比が取れないので、大きいほうの絶対値そのものを測る。
(define (test-close? x y)
  (let ((near (if (> (abs x) (abs y)) y x))
        (far (if (> (abs x) (abs y)) x y)))
    (if (zero? near)
        (< (abs far) test-epsilon)
        (< (abs (/ (- near far) far)) test-epsilon))))

;; 期待した値と得た値が合っているかを返す。`equal?` で等しければ合う。そうでなくても、
;; 期待した値が不正確な実数なら、得た値が実数で(正確でもよい)近ければ合う。期待した値が
;; 実数でない数なら、得た値も数であるときに、実部どうしと虚部どうしを、この規則で比べる。
;; 正確な実数と、数でない値は、`equal?` だけで決まる。
(define (test-match? expected actual)
  (cond ((equal? expected actual) #t)
        ((real? expected)
         (and (inexact? expected) (real? actual) (test-close? expected actual)))
        ((complex? expected)
         (and (complex? actual)
              (test-match? (real-part expected) (real-part actual))
              (test-match? (imag-part expected) (imag-part actual))))
        (else #f)))

;; 値を期待するテストを1件走らせて記録する。比較は `test-match?` である。
(define (test-run form expected thunk)
  (let ((outcome (test-outcome thunk)))
    (if (eq? (car outcome) 'raised)
        (test-results-add! form 'error expected (cadr outcome))
        (let ((actual (cadr outcome)))
          (test-results-add! form (if (test-match? expected actual) 'pass 'fail) expected actual)))))

;; 条件が上がることを期待するテストを1件走らせて記録する。
(define (test-run-error form thunk)
  (let ((outcome (test-outcome thunk)))
    (if (eq? (car outcome) 'raised)
        (test-results-add! form 'pass 'error (cadr outcome))
        (test-results-add! form 'fail 'error (cadr outcome)))))

;; スイートが使うのは、名前を省いた2引数の形だけである。
;; 期待した値の式は、誤りを捕まえる枠の外で評価する。その誤りは最上位へ上がる。上流は枠の中で
;; 評価し、誤りなら警告を出して期待を #f にして続けるので、ここは上流と違う。
(define-syntax test
  (syntax-rules ()
    ((_ expected expr) (test-run 'expr expected (lambda () expr)))))

;; スイートは名前つきの2引数の形を使う(`test-read-error` と `test-precision` の中)。名前は記録しない。
(define-syntax test-assert
  (syntax-rules ()
    ((_ expr) (test-run 'expr #t (lambda () (if expr #t #f))))
    ((_ name expr) (test-run 'expr #t (lambda () (if expr #t #f))))))

(define-syntax test-error
  (syntax-rules ()
    ((_ expr) (test-run-error 'expr (lambda () expr)))))

(define-syntax test-values
  (syntax-rules ()
    ((_ expected expr)
     (test-run 'expr
               (call-with-values (lambda () expected) list)
               (lambda () (call-with-values (lambda () expr) list))))))

(define (test-begin . name)
  (test-group-push! (if (pair? name) (car name) #f)))

(define (test-end . name)
  (test-group-pop!))
