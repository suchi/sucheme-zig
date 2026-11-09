;;; 二分探索: 整列済みのベクタから、半分ずつ範囲を狭めて値を探す。
(import (scheme base) (scheme write))

;; 見つかれば添字を、無ければ #f を返す。範囲は [lo, hi)。
(define (binary-search vec target)
  (let loop ((lo 0) (hi (vector-length vec)))
    (if (>= lo hi)
        #f
        (let* ((mid (quotient (+ lo hi) 2))
               (x (vector-ref vec mid)))
          (cond ((= x target) mid)
                ((< x target) (loop (+ mid 1) hi))
                (else (loop lo mid)))))))

(define primes #(2 3 5 7 11 13 17 19 23 29 31 37 41 43 47))

(define (report target)
  (display target)
  (display " -> ")
  (display (binary-search primes target))
  (newline))

(for-each report '(2 17 47 1 20 50))
(display (binary-search #() 1))
(newline)
