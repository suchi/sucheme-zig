;;; FizzBuzz: 1 から 30 まで、3 の倍数は Fizz、5 の倍数は Buzz、両方なら FizzBuzz と出す。
(import (scheme base) (scheme write))

(define (fizzbuzz n)
  (cond ((zero? (modulo n 15)) "FizzBuzz")
        ((zero? (modulo n 3)) "Fizz")
        ((zero? (modulo n 5)) "Buzz")
        (else n)))

(do ((i 1 (+ i 1)))
    ((> i 30))
  (display (fizzbuzz i))
  (newline))
