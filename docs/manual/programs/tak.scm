;;; 竹内関数 tak: 再帰呼び出しの多さでインタプリタの速さを測る定番の問題。
(import (scheme base) (scheme write))

(define calls 0)

(define (tak x y z)
  (set! calls (+ calls 1))
  (if (not (< y x))
      z
      (tak (tak (- x 1) y z)
           (tak (- y 1) z x)
           (tak (- z 1) x y))))

(display (tak 18 12 6))
(newline)
(display calls)
(display " calls")
(newline)
