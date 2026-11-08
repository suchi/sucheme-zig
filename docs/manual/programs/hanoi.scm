;;; ハノイの塔: n 枚の円盤を、中継を使って a から c へ移す手順を出す。
(import (scheme base) (scheme write))

(define count 0)

(define (move n from to via)
  (when (> n 0)
    (move (- n 1) from via to)
    (set! count (+ count 1))
    (display "move disk ") (display n)
    (display " from ") (display from)
    (display " to ") (display to)
    (newline)
    (move (- n 1) via to from)))

(move 3 'a 'c 'b)
(display count)
(display " moves")
(newline)

;; 手数は 2^n - 1 になる。
(set! count 0)
(define (silent-move n from to via)
  (when (> n 0)
    (silent-move (- n 1) from via to)
    (set! count (+ count 1))
    (silent-move (- n 1) via to from)))
(silent-move 10 'a 'c 'b)
(display count)
(newline)
