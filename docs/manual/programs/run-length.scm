;;; ランレングス符号化: 同じ文字の連続を (文字 . 個数) の対にまとめ、元に戻す。
(import (scheme base) (scheme write))

(define (encode str)
  (let loop ((chars (string->list str)) (acc '()))
    (cond ((null? chars) (reverse acc))
          ((and (pair? acc) (char=? (car (car acc)) (car chars)))
           (set-cdr! (car acc) (+ (cdr (car acc)) 1))
           (loop (cdr chars) acc))
          (else (loop (cdr chars) (cons (cons (car chars) 1) acc))))))

(define (decode runs)
  (apply string-append
         (map (lambda (run) (make-string (cdr run) (car run))) runs)))

;; 符号を "3a2b1c" のような文字列にする。
(define (runs->string runs)
  (apply string-append
         (map (lambda (run)
                (string-append (number->string (cdr run))
                               (string (car run))))
              runs)))

(define samples '("aaabbc" "abc" "zzzzzzzzzz" ""))
(for-each
 (lambda (str)
   (let ((runs (encode str)))
     (write str)
     (display " -> ")
     (write (runs->string runs))
     (display (if (string=? (decode runs) str) " (round trip ok)" " (MISMATCH)"))
     (newline)))
 samples)
