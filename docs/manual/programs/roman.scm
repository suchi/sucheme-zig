;;; ローマ数字の変換: 大きい記号から順に引いて作り、読むときは次の記号との大小で足し引きする。
(import (scheme base) (scheme write))

(define table
  '((1000 . "M") (900 . "CM") (500 . "D") (400 . "CD")
    (100 . "C") (90 . "XC") (50 . "L") (40 . "XL")
    (10 . "X") (9 . "IX") (5 . "V") (4 . "IV") (1 . "I")))

(define (->roman n)
  (let loop ((n n) (table table) (acc ""))
    (cond ((= n 0) acc)
          ((>= n (car (car table)))
           (loop (- n (car (car table))) table
                 (string-append acc (cdr (car table)))))
          (else (loop n (cdr table) acc)))))

(define (digit c)
  (case c
    ((#\I) 1) ((#\V) 5) ((#\X) 10) ((#\L) 50)
    ((#\C) 100) ((#\D) 500) ((#\M) 1000)))

;; 次の記号のほうが大きい記号は引き、そうでなければ足す。
(define (roman-> str)
  (let loop ((chars (string->list str)) (total 0))
    (cond ((null? chars) total)
          ((and (pair? (cdr chars)) (< (digit (car chars)) (digit (cadr chars))))
           (loop (cdr chars) (- total (digit (car chars)))))
          (else (loop (cdr chars) (+ total (digit (car chars))))))))

(for-each
 (lambda (n)
   (display n)
   (display " -> ")
   (display (->roman n))
   (display " -> ")
   (display (roman-> (->roman n)))
   (newline))
 '(1 4 9 14 40 90 400 1994 2024 3999))

;; 1 から 3999 まで、変換して戻すと元の数になる。
(display (let loop ((n 1))
           (cond ((> n 3999) "all round trips ok")
                 ((= (roman-> (->roman n)) n) (loop (+ n 1)))
                 (else n))))
(newline)
