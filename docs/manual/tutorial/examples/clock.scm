(import (scheme base) (scheme write) (scheme time))

(define (count-up n)
  (let loop ((i 0))
    (if (< i n) (loop (+ i 1)) i)))

(define start (current-jiffy))
(define result (count-up 100000))
(define seconds (/ (- (current-jiffy) start) (jiffies-per-second)))

(display result)
(newline)
(display (>= seconds 0))
(newline)
