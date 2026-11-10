(import (scheme base) (scheme write) (scheme process-context))

(define args (cdr (command-line)))

(if (null? args)
    (begin
      (display "usage: sum-args.scm NUMBER ...")
      (newline)
      (exit 2))
    (begin
      (display (apply + (map string->number args)))
      (newline)))
