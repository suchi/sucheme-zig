;;; wc 相当(ファイル版): 引数で渡されたファイルを読み、行数、語数、文字数を数える。
;;; 文字列ポートで入力を渡す `wc.scm` の対である。ファイルは `wc-file.files/` の下にあり、
;;; `wc-file.args` が `@files/` でそのパスを渡す。
(import (scheme base) (scheme char) (scheme file) (scheme process-context) (scheme write))

;; ポートを読み切り、(行数 語数 文字数) のリストを返す。
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

;; パスの、最後の区切り(`/` か `\`)より後ろを返す。絶対パスは環境で変わるので、
;; 出力にはファイルの名前だけを使う。
(define (base-name path)
  (let loop ((chars (string->list path)) (current '()))
    (cond ((null? chars) (list->string (reverse current)))
          ((or (char=? (car chars) #\/) (char=? (car chars) #\\))
           (loop (cdr chars) '()))
          (else (loop (cdr chars) (cons (car chars) current))))))

;; ファイルを数える。開けなければ #f を返す。
(define (count-file path)
  (guard (e ((file-error? e) #f))
    (call-with-input-file path wc)))

(define (show counts label)
  (for-each (lambda (n) (display (pad-left n 4))) counts)
  (display " ")
  (display label)
  (newline))

;; (command-line) の先頭はプログラムのファイルで、残りが引数である。
(define results
  (map (lambda (path)
         (let ((counts (count-file path)))
           (if counts
               (show counts (base-name path))
               (begin
                 (display (base-name path))
                 (display ": cannot be opened")
                 (newline)))
           counts))
       (cdr (command-line))))

;; リストから、#f でないものだけを残す(開けなかったファイルを除く)。
(define (keep-counts items)
  (cond ((null? items) '())
        ((car items) (cons (car items) (keep-counts (cdr items))))
        (else (keep-counts (cdr items)))))

;; 開けたファイルの合計を出す。
(show (apply map + (keep-counts results)) "total")
