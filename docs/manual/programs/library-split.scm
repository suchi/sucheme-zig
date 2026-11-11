;;; define-library で分けたプログラム: 長方形の部品と、その説明の部品を、別のファイルの
;;; ライブラリに分け、`-I` で探索ルートを指して読み込む。ライブラリは `library-split.files/lib/`
;;; の下にあり、`library-split.args` が `-I @files/lib` でそのディレクトリを指す。
(import (scheme base) (scheme write) (geometry shapes) (geometry report))

(define room (make-rect 4 3))

(describe "room" room)
(describe "doubled" (rect-scale room 2))
;; 辺を半分にすると、有理数の長さになる。
(describe "half" (rect-scale room 1/2))

;; 輸出した手続きは、ふつうの手続きと同じように組み合わせられる。
(display (+ (rect-area room) (rect-area (rect-scale room 2))))
(newline)
