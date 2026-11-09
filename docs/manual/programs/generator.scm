;;; 生成器: call/cc で、要素を 1 つ返しては中断し、次の呼び出しで再開する。
(import (scheme base) (scheme write))

(define (make-generator lst)
  (define return #f)
  (define (generate)
    (for-each
     (lambda (x)
       (call/cc
        (lambda (resume)
          (set! generate (lambda () (resume #f)))
          (return x))))
     lst)
    (return 'done))
  (lambda ()
    (call/cc
     (lambda (r)
       (set! return r)
       (generate)))))

(define g (make-generator '(a b c)))
(display (g)) (newline)
(display (g)) (newline)
(display (g)) (newline)
(display (g)) (newline)
(display (g)) (newline)

;; 別々の生成器は、別々の位置を持つ。
(define g1 (make-generator '(1 2 3)))
(define g2 (make-generator '(x y)))
(define (next-from g) (display (g)) (display " "))
(next-from g1)
(next-from g2)
(next-from g1)
(next-from g2)
(next-from g1)
(next-from g2)
(next-from g1)
(newline)
