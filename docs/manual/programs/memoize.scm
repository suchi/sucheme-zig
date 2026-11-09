;;; メモ化: 計算した結果を連想リストに覚え、同じ引数では再計算しない。
(import (scheme base) (scheme write))

(define call-count 0)

(define (memoize f)
  (let ((table '()))
    (lambda (n)
      (let ((hit (assv n table)))
        (if hit
            (cdr hit)
            (let ((v (f n)))
              (set! table (cons (cons n v) table))
              v))))))

;; 再帰の呼び出しもメモ化した手続きを通すため、名前を set! で結び直す。
(define (slow-fib n)
  (set! call-count (+ call-count 1))
  (if (< n 2)
      n
      (+ (slow-fib (- n 1)) (slow-fib (- n 2)))))

(define plain-result (slow-fib 20))
(display "plain: ")
(display plain-result)
(display " in ")
(display call-count)
(display " calls")
(newline)

(set! call-count 0)
(set! slow-fib (memoize slow-fib))
(define memo-result (slow-fib 20))
(display "memo: ")
(display memo-result)
(display " in ")
(display call-count)
(display " calls")
(newline)

;; 2 回目は、手続きの本体を 1 回も呼ばない。
(set! call-count 0)
(slow-fib 20)
(display "again: ")
(display call-count)
(display " calls")
(newline)
(display (slow-fib 80))
(newline)
