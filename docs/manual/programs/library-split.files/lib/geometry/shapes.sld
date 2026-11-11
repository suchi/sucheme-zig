;;; 長方形の部品。`-I` で指した探索ルートの下の `geometry/shapes.sld` として、
;;; `(import (geometry shapes))` から読まれる。
(define-library (geometry shapes)
  (import (scheme base))
  (export make-rect rect-width rect-height rect-area rect-perimeter rect-scale)
  (begin
    (define-record-type <rect>
      (make-rect width height)
      rect?
      (width rect-width)
      (height rect-height))

    (define (rect-area r)
      (* (rect-width r) (rect-height r)))

    (define (rect-perimeter r)
      (* 2 (+ (rect-width r) (rect-height r))))

    ;; 各辺を k 倍した長方形を返す。
    (define (rect-scale r k)
      (make-rect (* k (rect-width r)) (* k (rect-height r))))))
