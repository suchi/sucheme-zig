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

;; 値を期待するテストを1件走らせて記録する。比較は `equal?` である。
;; 上流は不正確な数を近似で比べるが、浮動小数点数が入るまでは書かない。
(define (test-run form expected thunk)
  (let ((outcome (test-outcome thunk)))
    (if (eq? (car outcome) 'raised)
        (test-results-add! form 'error expected (cadr outcome))
        (let ((actual (cadr outcome)))
          (test-results-add! form (if (equal? actual expected) 'pass 'fail) expected actual)))))

;; 条件が上がることを期待するテストを1件走らせて記録する。
(define (test-run-error form thunk)
  (let ((outcome (test-outcome thunk)))
    (if (eq? (car outcome) 'raised)
        (test-results-add! form 'pass 'error (cadr outcome))
        (test-results-add! form 'fail 'error (cadr outcome)))))

;; スイートが使うのは、名前を省いた2引数の形だけである。
(define-syntax test
  (syntax-rules ()
    ((_ expected expr) (test-run 'expr expected (lambda () expr)))))

(define-syntax test-assert
  (syntax-rules ()
    ((_ expr) (test-run 'expr #t (lambda () (if expr #t #f))))))

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
