;;; 順列と組合せ: リストから、すべての並べ方と選び方を作る。
(import (scheme base) (scheme write))

(define (flat-map f lst)
  (if (null? lst)
      '()
      (append (f (car lst)) (flat-map f (cdr lst)))))

(define (remove-first x lst)
  (cond ((null? lst) '())
        ((equal? x (car lst)) (cdr lst))
        (else (cons (car lst) (remove-first x (cdr lst))))))

;; 順列: 先頭を1つ選び、残りの順列の前に付ける。
(define (permutations lst)
  (if (null? lst)
      '(())
      (flat-map (lambda (x)
                  (map (lambda (p) (cons x p))
                       (permutations (remove-first x lst))))
                lst)))

;; 組合せ: 先頭を含むものと含まないものに分ける。
(define (combinations lst k)
  (cond ((= k 0) '(()))
        ((null? lst) '())
        (else (append (map (lambda (c) (cons (car lst) c))
                           (combinations (cdr lst) (- k 1)))
                      (combinations (cdr lst) k)))))

(define (show-all lst)
  (for-each (lambda (x) (display x) (newline)) lst))

(show-all (permutations '(a b c)))
(newline)
(show-all (combinations '(1 2 3 4) 2))
(newline)
(display (length (permutations '(1 2 3 4 5))))
(newline)
(display (length (combinations '(1 2 3 4 5 6 7 8 9 10) 3)))
(newline)
