(define-library (mylib greet)
  (export greet)
  (import (scheme base))
  (begin
    (define (prefix) "Hello, ")
    (define (greet name)
      (string-append (prefix) name "!"))))
