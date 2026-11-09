;;; 自作の制御構文: my-unless、my-or、for をマクロで作る。
(import (scheme base) (scheme write))

(define-syntax my-unless
  (syntax-rules ()
    ((_ test body ...)
     (if test #f (begin body ...)))))

;; 評価を左から順に行い、最初の真の値で止める。tmp は呼び出し側の名前と衝突しない。
(define-syntax my-or
  (syntax-rules ()
    ((_) #f)
    ((_ e) e)
    ((_ e rest ...)
     (let ((tmp e))
       (if tmp tmp (my-or rest ...))))))

;; (for x in list body ...) と (for x from a to b body ...) の 2 つの形を持つ。
(define-syntax for
  (syntax-rules (in from to)
    ((_ x in lst body ...)
     (for-each (lambda (x) body ...) lst))
    ((_ x from a to b body ...)
     (do ((x a (+ x 1)))
         ((> x b))
       body ...))))

(display (my-unless (> 1 2) 'ran))
(newline)
(display (my-unless (< 1 2) 'ran))
(newline)

(define tmp 'outer)
(display (my-or #f #f tmp))
(newline)
(display (my-or))
(newline)

;; 副作用のある式は、真の値が出たところで評価をやめる。
(my-or (begin (display "a ") #f)
       (begin (display "b ") 'found)
       (begin (display "never ") #t))
(newline)

(for x in '(a b c)
  (display x)
  (display " "))
(newline)
(for i from 1 to 5
  (display (* i i))
  (display " "))
(newline)
