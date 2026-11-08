;;; 整列: 挿入ソート、マージソート、クイックソートを同じ入力で比べる。
(import (scheme base) (scheme write))

;; 挿入ソート: 整列済みのリストに、1要素ずつ正しい位置へ挿入する。
(define (insert x sorted)
  (cond ((null? sorted) (list x))
        ((<= x (car sorted)) (cons x sorted))
        (else (cons (car sorted) (insert x (cdr sorted))))))

(define (insertion-sort lst)
  (let loop ((rest lst) (sorted '()))
    (if (null? rest)
        sorted
        (loop (cdr rest) (insert (car rest) sorted)))))

;; マージソート: 半分ずつ整列して、先頭を比べながら併合する。
(define (merge a b)
  (cond ((null? a) b)
        ((null? b) a)
        ((<= (car a) (car b)) (cons (car a) (merge (cdr a) b)))
        (else (cons (car b) (merge a (cdr b))))))

(define (split lst)
  (if (or (null? lst) (null? (cdr lst)))
      (values lst '())
      (let-values (((a b) (split (cddr lst))))
        (values (cons (car lst) a) (cons (cadr lst) b)))))

(define (merge-sort lst)
  (if (or (null? lst) (null? (cdr lst)))
      lst
      (let-values (((a b) (split lst)))
        (merge (merge-sort a) (merge-sort b)))))

;; クイックソート: 先頭を軸にして、小さいものと大きいものに分ける。
(define (filter keep? lst)
  (cond ((null? lst) '())
        ((keep? (car lst)) (cons (car lst) (filter keep? (cdr lst))))
        (else (filter keep? (cdr lst)))))

(define (quick-sort lst)
  (if (null? lst)
      '()
      (let ((pivot (car lst)) (rest (cdr lst)))
        (append (quick-sort (filter (lambda (x) (< x pivot)) rest))
                (list pivot)
                (quick-sort (filter (lambda (x) (>= x pivot)) rest))))))

(define data '(5 3 9 1 5 8 2 7 3 0 6 4))

(define (show label lst)
  (display label)
  (display ": ")
  (display lst)
  (newline))

(show "insertion" (insertion-sort data))
(show "merge    " (merge-sort data))
(show "quick    " (quick-sort data))
(show "empty    " (merge-sort '()))
