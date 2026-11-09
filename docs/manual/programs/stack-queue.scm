;;; スタックとキュー: レコード型で包み、キューは2つのリストで作る。
(import (scheme base) (scheme write))

;; スタック: リストの先頭に積む。
(define-record-type <stack>
  (make-stack items)
  stack?
  (items stack-items set-stack-items!))

(define (new-stack) (make-stack '()))
(define (stack-push! s x) (set-stack-items! s (cons x (stack-items s))))
(define (stack-pop! s)
  (let ((x (car (stack-items s))))
    (set-stack-items! s (cdr (stack-items s)))
    x))
(define (stack-empty? s) (null? (stack-items s)))

;; キュー: 入れる側のリストと取り出す側のリストを持つ。
;; 取り出す側が空のときだけ、入れる側を反転して移す。
(define-record-type <queue>
  (make-queue in out)
  queue?
  (in queue-in set-queue-in!)
  (out queue-out set-queue-out!))

(define (new-queue) (make-queue '() '()))
(define (enqueue! q x) (set-queue-in! q (cons x (queue-in q))))
(define (dequeue! q)
  (when (null? (queue-out q))
    (set-queue-out! q (reverse (queue-in q)))
    (set-queue-in! q '()))
  (let ((x (car (queue-out q))))
    (set-queue-out! q (cdr (queue-out q)))
    x))
(define (queue-empty? q)
  (and (null? (queue-in q)) (null? (queue-out q))))

(define s (new-stack))
(for-each (lambda (x) (stack-push! s x)) '(1 2 3))
(display "stack:")
(let loop ()
  (unless (stack-empty? s)
    (display " ")
    (display (stack-pop! s))
    (loop)))
(newline)

(define q (new-queue))
(for-each (lambda (x) (enqueue! q x)) '(1 2 3))
(display "queue:")
(display " ")
(display (dequeue! q))
(enqueue! q 4)
(let loop ()
  (unless (queue-empty? q)
    (display " ")
    (display (dequeue! q))
    (loop)))
(newline)

;; 括弧の対応をスタックで調べる。
(define (balanced? str)
  (let ((s (new-stack)))
    (let loop ((chars (string->list str)))
      (cond ((null? chars) (stack-empty? s))
            ((memv (car chars) '(#\( #\[))
             (stack-push! s (car chars))
             (loop (cdr chars)))
            ((memv (car chars) '(#\) #\]))
             (and (not (stack-empty? s))
                  (let ((open (stack-pop! s)))
                    (eqv? open (if (eqv? (car chars) #\)) #\( #\[)))
                  (loop (cdr chars))))
            (else (loop (cdr chars)))))))
(display (map balanced? '("(a [b] c)" "(]" "((" "")))
(newline)
