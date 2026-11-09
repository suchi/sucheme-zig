;;; 合成とカリー化: 手続きを受け取って手続きを返す。
(import (scheme base) (scheme write))

(define (compose . fs)
  (if (null? fs)
      (lambda (x) x)
      (lambda (x) ((car fs) ((apply compose (cdr fs)) x)))))

(define (curry f . first-args)
  (lambda rest-args (apply f (append first-args rest-args))))

(define (flip f) (lambda (a b) (f b a)))

(define add1 (curry + 1))
(define double (curry * 2))

(display ((compose double add1) 5))
(newline)
(display ((compose add1 double) 5))
(newline)
(display ((compose) 42))
(newline)

;; 3 つの手続きの合成を、リスト全体に適用する。
(define pipeline (compose number->string double add1))
(display (map pipeline '(1 2 3)))
(newline)

(display ((flip -) 1 10))
(newline)
(display (map (curry expt 2) '(0 1 2 3 10)))
(newline)
(display (map (flip expt) '(0 1 2 3) '(2 2 2 2)))
(newline)
