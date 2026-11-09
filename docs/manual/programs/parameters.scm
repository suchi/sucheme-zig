;;; parameterize による設定の切り替え: 動的な範囲の中だけ値を変える。
(import (scheme base) (scheme write))

(define indent (make-parameter 0))
(define bullet (make-parameter "-"))

(define (line text)
  (display (make-string (indent) #\space))
  (display (bullet))
  (display " ")
  (display text)
  (newline))

(define (nested text . children)
  (line text)
  (parameterize ((indent (+ (indent) 2)))
    (for-each (lambda (c) (apply nested c)) children)))

(nested "fruits"
        '("apple")
        (list "citrus" '("lemon") '("orange"))
        '("pear"))
(parameterize ((bullet "*"))
  (nested "vegetables" '("carrot")))
(line "back to the default")

;; 変換手続きを渡した引数は、parameterize の値にも変換がかかる。
(define radix (make-parameter 10 (lambda (n) (if (memv n '(2 8 10 16)) n (error "bad radix" n)))))
(define (show n) (display (number->string n (radix))) (newline))
(show 255)
(parameterize ((radix 16)) (show 255))
(parameterize ((radix 2)) (show 255))
(display (guard (e ((error-object? e) (error-object-message e)))
           (parameterize ((radix 7)) (show 255))))
(newline)
