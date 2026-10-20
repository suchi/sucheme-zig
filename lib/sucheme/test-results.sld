;; `(chibi test)` の結果を貯めて、値として返すライブラリ(docs/plans/0020-conformance-harness-early.md)。
;; 結果をポートに書かないのは、段階5のポートを待たずに準拠スイートを走らせるためである。
;; `(chibi test)` の輸出の名前と衝突しないよう、別のライブラリに分けた。
;;
;; 記録は `#(節の名前 テストの式 判定 期待した値 得た値)` で、判定は pass、fail、error のどれかである。
;; 節の名前は、いちばん内側の `test-begin` の名前で、どの節の中でもなければ #f である。
(define-library (sucheme test-results)
  (import (scheme base))
  (export test-results test-results-add! test-group-push! test-group-pop!)
  (begin
    ;; 新しい順に持ち、`test-results` が古い順に直して返す。
    (define records '())
    (define groups '())
    (define (test-results) (reverse records))
    (define (test-results-add! form status expected actual)
      (set! records
            (cons (vector (if (null? groups) #f (car groups)) form status expected actual)
                  records)))
    (define (test-group-push! name) (set! groups (cons name groups)))
    (define (test-group-pop!)
      (if (pair? groups) (set! groups (cdr groups))))))
