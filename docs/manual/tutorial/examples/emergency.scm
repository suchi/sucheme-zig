(import (scheme base) (scheme write) (scheme process-context))

(dynamic-wind
  (lambda () (display "start") (newline))
  (lambda () (emergency-exit 4))
  (lambda () (display "cleanup") (newline)))
