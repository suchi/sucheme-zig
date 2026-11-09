;;; fib のベンチマーク: 二重の再帰で fib(21) を計算する。
(import (scheme base) (scheme write))

(define calls 0)

(define (fib n)
  (set! calls (+ calls 1))
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))

(display (fib 21))
(newline)
(display calls)
(display " calls")
(newline)
