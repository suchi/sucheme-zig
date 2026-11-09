;;; 素因数分解: 小さい数から順に割って、(素数 . 指数) の列を作る。
(import (scheme base) (scheme write))

(define (factorize n)
  (let loop ((n n) (p 2) (acc '()))
    (cond ((= n 1) (reverse acc))
          ((> (* p p) n) (reverse (cons (cons n 1) acc)))
          ((zero? (remainder n p))
           (let count ((n n) (k 0))
             (if (zero? (remainder n p))
                 (count (quotient n p) (+ k 1))
                 (loop n (+ p 1) (cons (cons p k) acc)))))
          (else (loop n (+ p 1) acc)))))

(define (show-factors n)
  (display n)
  (display " =")
  (let loop ((fs (factorize n)) (first #t))
    (unless (null? fs)
      (display (if first " " " * "))
      (display (car (car fs)))
      (when (> (cdr (car fs)) 1)
        (display "^")
        (display (cdr (car fs))))
      (loop (cdr fs) #f)))
  (newline))

(for-each show-factors '(12 97 360 1001 65536 123456789 600851475143))

;; 積を取れば元の数に戻る。
(define (product fs)
  (apply * (map (lambda (f) (expt (car f) (cdr f))) fs)))
(display (= (product (factorize 600851475143)) 600851475143))
(newline)
