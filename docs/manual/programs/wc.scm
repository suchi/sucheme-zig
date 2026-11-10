;;; wc 相当: 入力ポートから、行数、語数、文字数を数える。
;;; 入力は文字列ポートで渡す。ファイルを読むときは、`open-input-string` の代わりに
;;; `open-input-file` で作ったポートを渡せば、同じ手続きが使える。
(import (scheme base) (scheme char) (scheme write))

;; ポートを読み切り、(行数 語数 文字数) のリストを返す。
;; wc と同じく、行数は改行文字の個数、語は空白で区切られた文字の連なりを数える。
(define (wc port)
  (let loop ((lines 0) (words 0) (chars 0) (in-word? #f))
    (let ((c (read-char port)))
      (cond ((eof-object? c) (list lines words chars))
            ((char-whitespace? c)
             (loop (if (char=? c #\newline) (+ lines 1) lines)
                   words
                   (+ chars 1)
                   #f))
            (else
             (loop lines
                   (if in-word? words (+ words 1))
                   (+ chars 1)
                   #t))))))

;; 数を幅 width の右寄せの文字列にする。
(define (pad-left n width)
  (let ((s (number->string n)))
    (if (< (string-length s) width)
        (string-append (make-string (- width (string-length s)) #\space) s)
        s)))

(define (report label str)
  (let ((counts (wc (open-input-string str))))
    (for-each (lambda (n) (display (pad-left n 4))) counts)
    (display " ")
    (display label)
    (newline)))

(report "empty" "")
(report "one-line" "hello world\n")
(report "no-newline" "no newline at the end")
(report "blank-lines" "first\n\n\n  last   line\n")
(report "japanese" "こんにちは 世界\n")

;; 3つの入力の合計も、足し算で求められる。
(define totals
  (map (lambda (str) (wc (open-input-string str)))
       '("a b\n" "c\n" "d e f\n")))
(display (apply map + totals))
(newline)
