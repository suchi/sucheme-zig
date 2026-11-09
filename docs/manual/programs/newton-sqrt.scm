;;; ニュートン法の平方根: 正確な数だと分数が膨らみ、不正確な数だと有限の桁で収束する。
(import (scheme base) (scheme inexact) (scheme write))

(define (improve guess x) (/ (+ guess (/ x guess)) 2))

(define (newton x guess steps)
  (let loop ((g guess) (i 0))
    (if (= i steps) g (loop (improve g x) (+ i 1)))))

;; 正確な数: 分数のまま。
(define exact-root (newton 2 1 4))
(display exact-root)
(newline)
(display (inexact exact-root))
(newline)

;; 不正確な数: 十分に収束したかを、二乗との差で判定する。
(define (sqrt-newton x)
  (let loop ((g 1.0) (steps 0))
    (if (< (abs (- (* g g) x)) 1e-12)
        (list g steps)
        (loop (improve g x) (+ steps 1)))))

(for-each
 (lambda (x)
   (let ((result (sqrt-newton x)))
     (display x)
     (display " -> ")
     (display (car result))
     (display " in ")
     (display (cadr result))
     (display " steps")
     (newline)))
 '(2.0 9.0 144.0 0.25))

(display (< (abs (- (car (sqrt-newton 2.0)) (sqrt 2.0))) 1e-9))
(newline)
