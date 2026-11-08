;;; たらい回し関数 tarai: 正格な版と、第 3 引数を遅延させた版で、呼び出しの回数を比べる。
(import (scheme base) (scheme write) (scheme lazy))

(define strict-calls 0)

;; 正格な版。第 3 引数 z を、毎回先に計算する。
(define (tarai x y z)
  (set! strict-calls (+ strict-calls 1))
  (if (<= x y)
      y
      (tarai (tarai (- x 1) y z)
             (tarai (- y 1) z x)
             (tarai (- z 1) x y))))

(define lazy-calls 0)

;; 遅延評価版。第 3 引数は promise で、必要になったときだけ force する。
;; x <= y なら z を使わないので、計算されない。
(define (tarai-lazy x y z)
  (set! lazy-calls (+ lazy-calls 1))
  (if (<= x y)
      y
      (tarai-lazy (tarai-lazy (- x 1) y z)
                  (tarai-lazy (- y 1) (force z) (delay x))
                  (delay (tarai-lazy (- (force z) 1) x (delay y))))))

(display (tarai 8 4 0))
(display " ")
(display strict-calls)
(display " calls")
(newline)

(display (tarai-lazy 12 6 (delay 0)))
(display " ")
(display lazy-calls)
(display " calls")
(newline)
