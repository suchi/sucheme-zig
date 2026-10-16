;; R7RS 7.3 の派生式。`(sucheme core)` の特殊形式と補助構文の上に、
;; `syntax-rules` で定義する。
;; 原文はこの環境から取得できないので、定義は記憶に基づく(未確認)。

(define-syntax when
  (syntax-rules ()
    ((_ test result1 result2 ...)
     (if test (begin result1 result2 ...)))))

(define-syntax unless
  (syntax-rules ()
    ((_ test result1 result2 ...)
     (if (not test) (begin result1 result2 ...)))))
