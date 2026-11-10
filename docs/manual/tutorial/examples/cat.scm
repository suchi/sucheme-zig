(import (scheme base) (scheme write) (scheme file) (scheme process-context))

(define (show-lines port n)
  (let ((line (read-line port)))
    (unless (eof-object? line)
      (display n)
      (display ": ")
      (display line)
      (newline)
      (show-lines port (+ n 1)))))

(call-with-input-file (cadr (command-line))
  (lambda (port) (show-lines port 1)))
