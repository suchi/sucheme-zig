;;; クロージャによる銀行口座: 残高はクロージャの中だけにあり、メッセージで操作する。
(import (scheme base) (scheme write))

(define (make-account balance)
  (define (deposit! amount)
    (set! balance (+ balance amount))
    balance)
  (define (withdraw! amount)
    (if (> amount balance)
        "insufficient funds"
        (begin (set! balance (- balance amount)) balance)))
  (lambda (message . args)
    (case message
      ((balance) balance)
      ((deposit) (apply deposit! args))
      ((withdraw) (apply withdraw! args))
      (else (error "unknown message" message)))))

(define a (make-account 100))
(define b (make-account 50))

(define (show label value)
  (display label)
  (display ": ")
  (display value)
  (newline))

(show "a deposit 20" (a 'deposit 20))
(show "a withdraw 70" (a 'withdraw 70))
(show "a withdraw 100" (a 'withdraw 100))
(show "b balance" (b 'balance))
(show "a balance" (a 'balance))

;; 口座ごとに別の残高を持つ。
(b 'deposit 5)
(show "b balance" (b 'balance))
(show "a balance" (a 'balance))

(guard (e ((error-object? e)
           (show "error" (error-object-message e))))
  (a 'close))
