;;; 調和数とベルヌーイ数: 有理数は分数のまま正確に計算できる。
(import (scheme base) (scheme write))

;; H(n) = 1 + 1/2 + ... + 1/n
(define (harmonic n)
  (let loop ((i 1) (sum 0))
    (if (> i n) sum (loop (+ i 1) (+ sum (/ 1 i))))))

(for-each
 (lambda (n)
   (display "H(")
   (display n)
   (display ") = ")
   (display (harmonic n))
   (newline))
 '(1 2 3 4 5 10 20))

(display "numerator and denominator of H(10): ")
(display (numerator (harmonic 10)))
(display " ")
(display (denominator (harmonic 10)))
(newline)

(display "inexact H(10): ")
(display (inexact (harmonic 10)))
(newline)

;; 二項係数 C(n, k)
(define (choose n k)
  (let loop ((i 1) (acc 1))
    (if (> i k) acc (loop (+ i 1) (/ (* acc (- n (- k i))) i)))))

;; ベルヌーイ数 B(0) から B(m): sum_{k=0}^{m} C(m+1, k) B(k) = 0 から求める。
(define (bernoulli-list count)
  (let loop ((m 0) (known '()))
    (if (= m count)
        (reverse known)
        (let ((b (if (= m 0)
                     1
                     (let sum ((k 0) (vals (reverse known)) (acc 0))
                       (if (null? vals)
                           (- (/ acc (+ m 1)))
                           (sum (+ k 1) (cdr vals)
                                (+ acc (* (choose (+ m 1) k) (car vals)))))))))
          (loop (+ m 1) (cons b known))))))

(display (bernoulli-list 11))
(newline)
