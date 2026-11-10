(import (scheme base) (scheme write) (scheme read) (scheme file))

(define name "roundtrip.tmp")

(call-with-output-file name
  (lambda (port)
    (write '(point (x . 1) (y . 2)) port)
    (newline port)
    (write "a \"quoted\" word" port)
    (newline port)))

(display (file-exists? name))
(newline)

(call-with-input-file name
  (lambda (port)
    (let* ((first (read port))
           (second (read port))
           (third (read port)))
      (write first)
      (newline)
      (write second)
      (newline)
      (write (eof-object? third))
      (newline))))

(delete-file name)
(display (file-exists? name))
(newline)
