(import (scheme base) (scheme write) (scheme process-context))

(dynamic-wind
  (lambda () (display "start") (newline))
  (lambda () (exit 3))
  (lambda () (display "cleanup") (newline)))
