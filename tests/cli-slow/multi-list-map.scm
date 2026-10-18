(import (sucheme procedures))
(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))
(define a (build 80000 '()))
(length (map (lambda (x y) x) a a))
