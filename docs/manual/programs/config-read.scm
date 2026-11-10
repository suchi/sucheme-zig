;;; read による設定の読み込み: 設定を Scheme のデータとして書いておき、`read` で読み込む。
;;; 設定の文字列は文字列ポートで渡す。ファイルから読むときは、`open-input-file` で作った
;;; ポートを渡す。
(import (scheme base) (scheme read) (scheme write))

(define config-text
  "; 画面の設定
   (width . 80)
   (height . 24)
   (title . \"sample\")
   (colors red green blue)
   (nested (a . 1) (b . #t))")

;; ポートからデータを読み切り、リストで返す。
(define (read-all port)
  (let loop ((acc '()))
    (let ((x (read port)))
      (if (eof-object? x)
          (reverse acc)
          (loop (cons x acc))))))

(define config (read-all (open-input-string config-text)))

;; キーに対応する値を返す。無ければ default を返す。
;; (key a b c) の形の値は、リスト (a b c) として返る。
(define (config-ref key default)
  (let ((entry (assq key config)))
    (if entry (cdr entry) default)))

(write (config-ref 'width 0))
(newline)
(write (config-ref 'title "none"))
(newline)
(write (config-ref 'colors '()))
(newline)
(write (config-ref 'missing 'default))
(newline)
(write (config-ref 'nested '()))
(newline)

;; 設定の面積。読んだ値は数なので、そのまま計算できる。
(write (* (config-ref 'width 0) (config-ref 'height 0)))
(newline)

;; 書き出したものは、読み直すと同じ設定に戻る。
(define out (open-output-string))
(for-each (lambda (entry) (write entry out) (newline out)) config)
(define reread (read-all (open-input-string (get-output-string out))))
(write (equal? config reread))
(newline)

;; 読み取りの誤りは、`read-error?` で見分けられる。
(define (safe-read str)
  (guard (e ((read-error? e) 'read-error))
    (read (open-input-string str))))
(write (safe-read "(width . 80)"))
(newline)
(write (safe-read "(width . 80"))
(newline)
(write (safe-read ")"))
(newline)
