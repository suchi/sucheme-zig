;;; シーザー暗号: 英字を決まった数だけずらす。大文字小文字は保ち、他の文字はそのまま。
(import (scheme base) (scheme char) (scheme write))

(define (shift-char c k)
  (define (rotate base)
    (integer->char
     (+ base (modulo (+ (- (char->integer c) base) k) 26))))
  (cond ((char-upper-case? c) (rotate (char->integer #\A)))
        ((char-lower-case? c) (rotate (char->integer #\a)))
        (else c)))

(define (caesar str k)
  (string-map (lambda (c) (shift-char c k)) str))

(define message "Hello, World!")
(define secret (caesar message 3))
(display secret)
(newline)
(display (caesar secret -3))
(newline)

;; 13 ずらすと、もう一度かけて元に戻る。
(display (caesar (caesar message 13) 13))
(newline)

;; 全部の鍵を試して、元の文字列が出る鍵を探す。
(define (crack encrypted known)
  (let loop ((k 0))
    (cond ((= k 26) #f)
          ((string=? (caesar encrypted (- k)) known) k)
          (else (loop (+ k 1))))))
(display (crack secret message))
(newline)
