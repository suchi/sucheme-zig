;;; エラトステネスのふるい: ベクタに印を付けて、100 以下の素数を求める。
(import (scheme base) (scheme write))

(define (primes-up-to n)
  (let ((composite (make-vector (+ n 1) #f)))
    (let loop ((i 2) (found '()))
      (cond ((> i n) (reverse found))
            ((vector-ref composite i) (loop (+ i 1) found))
            (else
             ;; i の倍数に印を付ける。i * i より小さい倍数は、すでに印が付いている。
             (do ((j (* i i) (+ j i)))
                 ((> j n))
               (vector-set! composite j #t))
             (loop (+ i 1) (cons i found)))))))

(define result (primes-up-to 100))
(display result)
(newline)
(display (length result))
(display " primes")
(newline)
