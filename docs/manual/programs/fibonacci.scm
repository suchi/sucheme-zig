;;; フィボナッチ数: 再帰、反復、メモ化を比べる。
(import (scheme base) (scheme write))

;; 二重の再帰。同じ値を何度も計算するので、n が大きいと遅い。
(define (fib-rec n)
  (if (< n 2)
      n
      (+ (fib-rec (- n 1)) (fib-rec (- n 2)))))

;; 反復。末尾呼び出しなので、ループになる。
(define (fib-iter n)
  (let loop ((a 0) (b 1) (i 0))
    (if (= i n)
        a
        (loop b (+ a b) (+ i 1)))))

;; メモ化。計算した値を連想リストに覚える。
(define (make-memo-fib)
  (let ((memo '()))
    (define (fib n)
      (cond ((< n 2) n)
            ((assv n memo) => cdr)
            (else
             (let ((v (+ (fib (- n 1)) (fib (- n 2)))))
               (set! memo (cons (cons n v) memo))
               v))))
    fib))

(define fib-memo (make-memo-fib))

(define (show n)
  (display n)
  (display ": ")
  (display (fib-rec n))
  (display " ")
  (display (fib-iter n))
  (display " ")
  (display (fib-memo n))
  (newline))

(for-each show '(0 1 2 10 20))

;; 反復とメモ化は、再帰が終わらない大きさでも答える(bignum になる)。
(display (fib-iter 100))
(newline)
(display (= (fib-iter 100) (fib-memo 100)))
(newline)
