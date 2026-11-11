;;; 長方形を1行で説明する部品。別のライブラリ `(geometry shapes)` を読み込む。
(define-library (geometry report)
  (import (scheme base) (scheme write) (geometry shapes))
  (export describe)
  (begin
    ;; 名前、辺の長さ、面積、周の長さを1行に書く。
    (define (describe name r)
      (display name)
      (display ": ")
      (display (rect-width r))
      (display "x")
      (display (rect-height r))
      (display " area ")
      (display (rect-area r))
      (display " perimeter ")
      (display (rect-perimeter r))
      (newline))))
