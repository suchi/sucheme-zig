;;; 最大公約数と最小公倍数: ユークリッドの互除法。
(import (scheme base) (scheme write))

(define (my-gcd a b)
  (if (= b 0)
      a
      (my-gcd b (remainder a b))))

(define (my-lcm a b)
  (quotient (* a b) (my-gcd a b)))

(define (show a b)
  (display "gcd(") (display a) (display ", ") (display b) (display ") = ")
  (display (my-gcd a b))
  (display ", lcm = ")
  (display (my-lcm a b))
  (newline))

(show 12 18)
(show 17 5)
(show 100 75)
(show 1071 462)

;; 組み込みの gcd と lcm と一致することを確かめる。
(display (and (= (my-gcd 1071 462) (gcd 1071 462))
              (= (my-lcm 12 18) (lcm 12 18))))
(newline)
