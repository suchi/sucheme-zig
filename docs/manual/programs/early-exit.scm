;;; 早期脱出: call/cc に渡された脱出用の手続きで、深い入れ子の処理から一気に抜ける。
(import (scheme base) (scheme write))

;; 積を求める。0 が現れたら、残りを調べずに 0 を返す。
(define multiplications 0)
(define (product lst)
  (call/cc
   (lambda (exit)
     (let loop ((lst lst))
       (cond ((null? lst) 1)
             ((= (car lst) 0) (exit 0))
             (else
              (set! multiplications (+ multiplications 1))
              (* (car lst) (loop (cdr lst)))))))))

(display (product '(1 2 3 4 5)))
(newline)
(display multiplications)
(newline)
(set! multiplications 0)
(display (product '(2 3 0 4 5)))
(newline)
(display multiplications)
(newline)

;; 木の中から条件に合う最初の葉を探す。見つかったら再帰全体から抜ける。
(define (find-leaf pred tree)
  (call/cc
   (lambda (return)
     (let walk ((t tree))
       (cond ((pair? t) (walk (car t)) (walk (cdr t)))
             ((null? t) #f)
             ((pred t) (return t))
             (else #f)))
     #f)))

(define tree '((1 (3 5)) (4 (7 8)) 9))
(display (find-leaf even? tree))
(newline)
(display (find-leaf (lambda (x) (> x 100)) tree))
(newline)

;; dynamic-wind は、脱出でも後始末を実行する。
(call/cc
 (lambda (k)
   (dynamic-wind
     (lambda () (display "enter") (newline))
     (lambda () (k 'escaped) (display "not reached") (newline))
     (lambda () (display "leave") (newline)))))
