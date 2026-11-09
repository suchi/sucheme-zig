(import (scheme write))
(display "to standard output")
(newline)
(write-string "to standard error\n" (current-error-port))
