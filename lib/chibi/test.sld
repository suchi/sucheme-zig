;; chibi-scheme の `(chibi test)` と互換の最小実装(docs/plans/0020-conformance-harness-early.md)。
;; 準拠スイート(tests/vendor/r7rs-tests.scm)が使う6つの形式だけを持つ。上流の実装は
;; chibi 固有のライブラリを読み込むので、取り込まずに自前で書く(ADR-0013)。
;; 結果は `(sucheme test-results)` に貯める。
(define-library (chibi test)
  (import (scheme base) (sucheme test-results))
  (export test test-assert test-error test-values test-begin test-end)
  (include "test.scm"))
