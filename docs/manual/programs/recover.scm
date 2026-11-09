;;; with-exception-handler と raise-continuable: 誤りを処理して、その場から計算を続ける。
(import (scheme base) (scheme write))

;; ハンドラが返した値が、raise-continuable の値になる。
(define (read-setting key)
  (raise-continuable (list 'missing-setting key)))

(define (with-defaults thunk)
  (with-exception-handler
   (lambda (e)
     (if (and (pair? e) (eq? (car e) 'missing-setting))
         (case (cadr e)
           ((width) 80)
           ((height) 24)
           (else 0))
         (raise-continuable e)))
   thunk))

(display (with-defaults
          (lambda ()
            (list (read-setting 'width)
                  (read-setting 'height)
                  (read-setting 'depth)))))
(newline)

;; 回復した回数を数える。
(define recovered 0)
(define total
  (with-exception-handler
   (lambda (e)
     (set! recovered (+ recovered 1))
     0)
   (lambda ()
     (+ (raise-continuable 'first)
        10
        (raise-continuable 'second)
        5))))
(display (list total recovered))
(newline)

;; raise で投げた値は、ハンドラが返ったあとにもう一つの誤りになる。
;; guard で外側から受けて確かめる。
(display
 (guard (e (#t (list 'secondary-error (error-object? e))))
   (with-exception-handler
    (lambda (e) 'ignored)
    (lambda () (raise 'boom)))))
(newline)
