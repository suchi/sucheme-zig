;;; 99 本のビール: 数が 1 のときの単複と、0 本のときの歌詞の違いを場合分けで書く。
(import (scheme base) (scheme write))

(define (bottles n)
  (cond ((= n 0) "no more bottles")
        ((= n 1) "1 bottle")
        (else (string-append (number->string n) " bottles"))))

(define (verse n)
  (display (bottles n))
  (display " of beer on the wall, ")
  (display (bottles n))
  (display " of beer.")
  (newline)
  (if (= n 0)
      (display "Go to the store and buy some more, 99 bottles of beer on the wall.")
      (begin
        (display "Take one down and pass it around, ")
        (display (bottles (- n 1)))
        (display " of beer on the wall.")))
  (newline))

;; 全部は長いので、始めの 3 節と終わりの 3 節を出す。
(do ((n 99 (- n 1)))
    ((< n 97))
  (verse n)
  (newline))
(do ((n 2 (- n 1)))
    ((< n 0))
  (verse n)
  (unless (= n 0) (newline)))
