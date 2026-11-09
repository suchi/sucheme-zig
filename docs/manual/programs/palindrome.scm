;;; 回文の判定: 英字だけを小文字にして残し、前から読んだ列と後ろから読んだ列を比べる。
(import (scheme base) (scheme char) (scheme write))

(define (normalize str)
  (let loop ((chars (string->list str)) (acc '()))
    (cond ((null? chars) (list->string (reverse acc)))
          ((char-alphabetic? (car chars))
           (loop (cdr chars) (cons (char-downcase (car chars)) acc)))
          (else (loop (cdr chars) acc)))))

(define (palindrome? str)
  (let ((s (normalize str)))
    (string=? s (list->string (reverse (string->list s))))))

(define samples
  '("racecar"
    "A man, a plan, a canal: Panama"
    "Was it a car or a cat I saw?"
    "hello"
    ""))

(for-each
 (lambda (str)
   (write str)
   (display (if (palindrome? str) " is a palindrome" " is not a palindrome"))
   (newline))
 samples)
