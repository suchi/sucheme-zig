;;; 連想リストの電話帳: 追加、検索、更新、削除を、リストを作り直す形で行う。
(import (scheme base) (scheme write))

(define (add-entry book name number)
  (cons (cons name number) book))

(define (lookup book name)
  (let ((entry (assoc name book)))
    (if entry (cdr entry) #f)))

;; 同じ名前の項目を置き換える。無ければ追加する。
(define (update-entry book name number)
  (cond ((null? book) (list (cons name number)))
        ((string=? (car (car book)) name)
         (cons (cons name number) (cdr book)))
        (else (cons (car book) (update-entry (cdr book) name number)))))

(define (remove-entry book name)
  (cond ((null? book) '())
        ((string=? (car (car book)) name) (cdr book))
        (else (cons (car book) (remove-entry (cdr book) name)))))

(define (show-book book)
  (for-each
   (lambda (entry)
     (display (car entry))
     (display ": ")
     (display (cdr entry))
     (newline))
   book))

(define book '())
(set! book (add-entry book "alice" "555-0101"))
(set! book (add-entry book "bob" "555-0102"))
(set! book (add-entry book "carol" "555-0103"))
(show-book book)

(display (lookup book "bob"))
(newline)
(display (lookup book "dave"))
(newline)

(set! book (update-entry book "bob" "555-9999"))
(set! book (update-entry book "dave" "555-0104"))
(show-book book)

(set! book (remove-entry book "alice"))
(display (map car book))
(newline)
