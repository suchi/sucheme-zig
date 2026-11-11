;;; ファイルの書き込みと読み込みの往復: 作業ディレクトリにファイルを作り、読み戻し、消す。
;;; `check-examples` は、プログラムを空の一時ディレクトリで走らせ、終わったら、そのディレクトリを
;;; 消す。そのため、最初の `file-exists?` は偽で、プログラムが残したファイルは実行のあとに残らない。
(import (scheme base) (scheme file) (scheme read) (scheme write))

(define name "roundtrip.txt")

(define (show label value)
  (display label)
  (display ": ")
  (write value)
  (newline))

(show "before" (file-exists? name))

;; 作業ディレクトリは、文書のディレクトリではない(そこには `README.md` がある)。
(show "README.md here" (file-exists? "README.md"))

;; データと文字列の行を書く。`write` で書いたデータは、`read` で読み戻せる。
(call-with-output-file name
  (lambda (out)
    (write '(1 "two" #\3 (4 . 5) #(6 7)) out)
    (newline out)
    (write-string "plain second line" out)
    (newline out)))
(show "after writing" (file-exists? name))

;; 読み戻す。`read` はデータの後ろの改行を残すので、そこから行ごとに読む。
(call-with-input-file name
  (lambda (in)
    (show "datum" (read in))
    (show "rest of line" (read-line in))
    (show "next line" (read-line in))
    (show "end" (eof-object? (read-line in)))))

;; 同じ名前を開き直すと、中身は上書きされる。
(call-with-output-file name
  (lambda (out) (write-string "overwritten" out)))
(show "overwritten" (call-with-input-file name read-line))

(delete-file name)
(show "after deleting" (file-exists? name))

;; 消したファイルを開こうとすると、ファイルの誤りになる。
(show "opening a deleted file"
      (guard (e ((file-error? e) 'file-error))
        (open-input-file name)))
