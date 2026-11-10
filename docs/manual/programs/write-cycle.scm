;;; write による循環構造の表示: 循環したデータと、共有したデータを、
;;; `write`、`write-shared`、`write-simple` で書き出す。
(import (scheme base) (scheme cxr) (scheme read) (scheme write))

;; 文字列に書き出す。
(define (written proc datum)
  (let ((port (open-output-string)))
    (proc datum port)
    (get-output-string port)))

(define (show label str)
  (display label)
  (display ": ")
  (display str)
  (newline))

;; 1. 循環したリスト。最後の cdr を先頭に結ぶ。
(define ring (list 'a 'b 'c))
(set-cdr! (cddr ring) ring)
(show "ring" (written write ring))

;; 2. 自分自身を要素に持つベクタ。
(define self (vector 1 2 #f))
(vector-set! self 2 self)
(show "self" (written write self))

;; 3. 共有。循環していないので、`write` はラベルを付けない。
(define shared (list 1 2))
(define pair-of-shared (list shared shared))
(show "write" (written write pair-of-shared))
(show "write-shared" (written write-shared pair-of-shared))
(show "write-simple" (written write-simple pair-of-shared))

;; 4. 2つの循環が絡む例。ラベルは0番から振られる。
(define x (list 'x))
(define y (list 'y))
(set-cdr! x y)
(set-cdr! y x)
(show "two-cycle" (written write (list x y)))

;; 5. 書き出したものは、`read` で読み直すと、同じ形の循環に戻る。
(define reread (read (open-input-string (written write ring))))
(show "reread" (written write reread))
(display "same shape: ")
(display (and (eq? (car reread) 'a)
              (eq? (caddr reread) 'c)
              (eq? (cdddr reread) reread)))
(newline)

;; 6. 循環の検出。ウサギとカメの方法で、進むのが遅い印と速い印がぶつかれば循環している。
(define (cyclic? lst)
  (let loop ((slow lst) (fast lst))
    (cond ((or (null? fast) (null? (cdr fast))) #f)
          (else
           (let ((slow (cdr slow))
                 (fast (cddr fast)))
             (or (eq? slow fast)
                 (loop slow fast)))))))

(display "ring is cyclic: ")
(display (cyclic? ring))
(newline)
(display "list is cyclic: ")
(display (cyclic? (list 1 2 3 4)))
(newline)
