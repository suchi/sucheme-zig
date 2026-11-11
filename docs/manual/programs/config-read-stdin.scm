;;; read による設定の読み込み(標準入力版): 標準入力から Scheme のデータを1つずつ読み、
;;; 番号をつけて書き出す。入力は `config-read-stdin.in` で、`config-read.scm` が文字列ポートで
;;; 渡した設定の形と同じである。最後のデータは閉じていないので、`read-error?` で見分ける。
(import (scheme base) (scheme read) (scheme write))

;; 標準入力から読めるだけ読み、読めたデータの個数を返す。
;; 読み取りの誤りが出たら、そこで止めて、誤りを見たことを知らせる。
(define (read-all port)
  (let loop ((n 0))
    (let ((x (guard (e ((read-error? e) 'read-error))
               (read port))))
      (cond ((eof-object? x) (list 'eof n))
            ((eq? x 'read-error) (list 'read-error n))
            (else
             (display n)
             (display ": ")
             (write x)
             (newline)
             (loop (+ n 1)))))))

(define result (read-all (current-input-port)))
(display "stopped by ")
(display (car result))
(display " after ")
(display (cadr result))
(display " data")
(newline)
