;;; CSV の1行の分割: 引用符で囲んだ欄の中のコンマと、"" で表す引用符を扱う。
(import (scheme base) (scheme write))

;; 文字のリストを欄のリストに分ける。
;; in-quote が #t の間は、コンマも欄の区切りにしない。
(define (split-fields chars)
  (let loop ((chars chars) (field '()) (fields '()) (in-quote #f))
    (define (finish) (cons (list->string (reverse field)) fields))
    (cond ((null? chars) (reverse (finish)))
          ((and in-quote (char=? (car chars) #\")
                (pair? (cdr chars)) (char=? (cadr chars) #\"))
           (loop (cddr chars) (cons #\" field) fields #t))
          ((char=? (car chars) #\")
           (loop (cdr chars) field fields (not in-quote)))
          ((and (not in-quote) (char=? (car chars) #\,))
           (loop (cdr chars) '() (finish) #f))
          (else (loop (cdr chars) (cons (car chars) field) fields in-quote)))))

(define (parse-line line) (split-fields (string->list line)))

(define (show-fields fields)
  (let loop ((fields fields) (i 1))
    (unless (null? fields)
      (display i)
      (display ": [")
      (display (car fields))
      (display "]")
      (newline)
      (loop (cdr fields) (+ i 1)))))

(show-fields (parse-line "name,age,city"))
(show-fields (parse-line "\"Smith, John\",42,\"say \"\"hi\"\"\""))
(show-fields (parse-line "a,,c,"))
(display (length (parse-line "")))
(newline)
