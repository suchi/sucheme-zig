;;; while: 条件が真の間、本体を繰り返すマクロ。再帰する末尾呼び出しに展開する。
(import (scheme base) (scheme write))

(define-syntax while
  (syntax-rules ()
    ((_ condition body ...)
     (let loop ()
       (when condition
         body ...
         (loop))))))

(define i 0)
(while (< i 5)
  (display i)
  (display " ")
  (set! i (+ i 1)))
(newline)

;; 入れ子にしても、それぞれの loop は別の束縛になる。
(define row 1)
(while (<= row 3)
  (let ((col 1))
    (while (<= col row)
      (display (* row col))
      (display " ")
      (set! col (+ col 1))))
  (newline)
  (set! row (+ row 1)))

;; 大きな回数でも、末尾呼び出しなので深さは増えない。
(define n 0)
(while (< n 100000)
  (set! n (+ n 1)))
(display n)
(newline)
