;;; 大きな階乗: 正確な整数は桁あふれしない。桁数や末尾の 0 の数も求める。
(import (scheme base) (scheme write))

(define (factorial n)
  (let loop ((i 2) (acc 1))
    (if (> i n) acc (loop (+ i 1) (* acc i)))))

(for-each
 (lambda (n)
   (display n)
   (display "! = ")
   (display (factorial n))
   (newline))
 '(0 5 20 25))

(define (digit-count n) (string-length (number->string n)))
(display "digits of 100!: ")
(display (digit-count (factorial 100)))
(newline)

;; 末尾に並ぶ 0 の数は、10 で割り切れる回数。
(define (trailing-zeros n)
  (let loop ((n n) (count 0))
    (if (zero? (remainder n 10))
        (loop (quotient n 10) (+ count 1))
        count)))
(display "trailing zeros of 100!: ")
(display (trailing-zeros (factorial 100)))
(newline)

;; 2 の累乗も同じく正確に求まる。
(display (expt 2 100))
(newline)
(display (exact? (factorial 30)))
(newline)
;; 割り算の商と余りで、桁を分ける。
(call-with-values
    (lambda () (floor/ (factorial 30) (expt 10 20)))
  (lambda (q r)
    (display q)
    (display " ")
    (display r)
    (newline)))
