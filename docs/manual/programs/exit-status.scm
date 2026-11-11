;;; 終了コードを返すプログラム: いくつかの検査を走らせ、失敗した個数を終了コードにする。
;;; `exit` の引数が、プロセスの終了コードになる。期待する出力の最後の行 `[exit 2]` が、
;;; `check-examples` に、終了コード 2 を求めさせる。
(import (scheme base) (scheme process-context) (scheme write))

;; (名前 . 結果) の表。結果が #f の検査が失敗である。
(define checks
  (list (cons "addition" (= (+ 1 2) 3))
        (cons "string order" (string<? "apple" "banana"))
        (cons "exact division" (= (/ 1 3) 0.333))
        (cons "list length" (= (length '(a b c)) 4))
        (cons "vector fill" (equal? (make-vector 2 'x) #(x x)))))

(define failures 0)

(for-each
 (lambda (check)
   (display (if (cdr check) "pass " "FAIL "))
   (display (car check))
   (newline)
   (if (not (cdr check))
       (set! failures (+ failures 1))))
 checks)

(display failures)
(display " of ")
(display (length checks))
(display " checks failed")
(newline)

;; 失敗が無ければ 0、あれば失敗の個数で終わる。
(exit failures)
