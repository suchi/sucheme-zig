;;; guard と raise による入力の検査: 誤りの種類ごとに、値を投げて受け分ける。
(import (scheme base) (scheme write))

;; 年齢の入力を検査する。誤りは、種類を表すシンボルと詳細のリストとして投げる。
(define (parse-age str)
  (let ((n (string->number str)))
    (cond ((not n) (raise (list 'not-a-number str)))
          ((not (exact-integer? n)) (raise (list 'not-an-integer n)))
          ((< n 0) (raise (list 'negative n)))
          ((> n 150) (raise (list 'too-large n)))
          (else n))))

(define (check str)
  (guard (e ((and (pair? e) (eq? (car e) 'not-a-number))
             (list "not a number:" (cadr e)))
            ((and (pair? e) (memq (car e) '(negative too-large)))
             (list "out of range:" (cadr e)))
            ((pair? e) (list "other problem:" (car e))))
    (list "ok:" (parse-age str))))

(for-each
 (lambda (s)
   (write s)
   (display " -> ")
   (write (check s))
   (newline))
 '("42" "abc" "-3" "200" "1.5"))

;; error で作った誤りのオブジェクトは、メッセージと関係する値を取り出せる。
(define (safe-div a b)
  (if (zero? b)
      (error "division by zero:" a)
      (/ a b)))
(guard (e ((error-object? e)
           (display (error-object-message e))
           (display " ")
           (display (error-object-irritants e))
           (newline)))
  (safe-div 10 0))

;; どの節にも合わない誤りは、guard の外へ再び投げられる。
(guard (outer (#t (display "outer caught ") (display outer) (newline)))
  (guard (inner ((string? inner) (display "inner caught string") (newline)))
    (raise 'a-symbol)))
