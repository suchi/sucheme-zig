(define-library (mylib greet)
  (import (scheme base) (scheme write))
  (export greet)
  (begin
    (define (greet name)
      (display "Hello, ")
      (display name)
      (newline))))
