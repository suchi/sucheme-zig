;;; swap!: 2 つの変数の値を入れ替えるマクロ。衛生的なので、一時変数の名前が衝突しない。
(import (scheme base) (scheme write))

(define-syntax swap!
  (syntax-rules ()
    ((_ a b)
     (let ((tmp a))
       (set! a b)
       (set! b tmp)))))

(define x 1)
(define y 2)
(swap! x y)
(display (list x y))
(newline)

;; 利用者の変数が tmp という名前でも、マクロの tmp とは別の束縛になる。
(define tmp 10)
(define other 20)
(swap! tmp other)
(display (list tmp other))
(newline)

(let ((a 'left) (b 'right))
  (swap! a b)
  (display (list a b))
  (newline))

;; ベクタの要素の入れ替えは、手続きにする。マクロは変数に set! する形に限る。
(define v (vector 1 2 3))
(define (vector-swap! v i j)
  (let ((t (vector-ref v i)))
    (vector-set! v i (vector-ref v j))
    (vector-set! v j t)))
(vector-swap! v 0 2)
(display v)
(newline)
