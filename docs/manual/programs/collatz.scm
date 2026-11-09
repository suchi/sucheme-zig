;;; コラッツの数列: 偶数なら半分、奇数なら 3 倍して 1 を足す。いつか 1 に着くと予想されている。
(import (scheme base) (scheme write))

(define (next n)
  (if (even? n) (quotient n 2) (+ (* 3 n) 1)))

(define (sequence n)
  (let loop ((n n) (acc '()))
    (if (= n 1)
        (reverse (cons 1 acc))
        (loop (next n) (cons n acc)))))

(display (sequence 6))
(newline)
(display (sequence 27))
(newline)

(define (steps n) (- (length (sequence n)) 1))
(display (steps 27))
(newline)

;; 1 から 1000 までで、最も長くかかる数を探す。
(define (longest limit)
  (let loop ((n 1) (best 1) (best-steps 0))
    (if (> n limit)
        (cons best best-steps)
        (let ((s (steps n)))
          (if (> s best-steps)
              (loop (+ n 1) n s)
              (loop (+ n 1) best best-steps))))))
(let ((result (longest 1000)))
  (display (car result))
  (display " takes ")
  (display (cdr result))
  (display " steps")
  (newline))
