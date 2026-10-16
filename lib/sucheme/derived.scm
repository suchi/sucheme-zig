;; R7RS 7.3 の派生式。`(sucheme core)` の特殊形式と補助構文の上に、
;; `syntax-rules` で定義する。
;; 定義は R7RS 7.3(誤記修正版の原文 docs/spec/errata-corrected-r7rs.pdf)から写した。
;; 原文が与えない `quasiquote` は、このファイルで書いた(下の注を参照)。
;;
;; `%` で始まる名前は、このファイルの中だけで使う内部用の名前で、エクスポートしない。

(define-syntax cond
  (syntax-rules (else =>)
    ((cond (else result1 result2 ...))
     (begin result1 result2 ...))
    ((cond (test => result))
     (let ((temp test))
       (if temp (result temp))))
    ((cond (test => result) clause1 clause2 ...)
     (let ((temp test))
       (if temp
           (result temp)
           (cond clause1 clause2 ...))))
    ((cond (test)) test)
    ((cond (test) clause1 clause2 ...)
     (let ((temp test))
       (if temp
           temp
           (cond clause1 clause2 ...))))
    ((cond (test result1 result2 ...))
     (if test (begin result1 result2 ...)))
    ((cond (test result1 result2 ...)
           clause1 clause2 ...)
     (if test
         (begin result1 result2 ...)
         (cond clause1 clause2 ...)))))

(define-syntax case
  (syntax-rules (else =>)
    ((case (key ...)
       clauses ...)
     (let ((atom-key (key ...)))
       (case atom-key clauses ...)))
    ((case key
       (else => result))
     (result key))
    ((case key
       (else result1 result2 ...))
     (begin result1 result2 ...))
    ((case key
       ((atoms ...) => result))
     (if (memv key '(atoms ...))
         (result key)))
    ((case key
       ((atoms ...) result1 result2 ...))
     (if (memv key '(atoms ...))
         (begin result1 result2 ...)))
    ((case key
       ((atoms ...) => result)
       clause clauses ...)
     (if (memv key '(atoms ...))
         (result key)
         (case key clause clauses ...)))
    ((case key
       ((atoms ...) result1 result2 ...)
       clause clauses ...)
     (if (memv key '(atoms ...))
         (begin result1 result2 ...)
         (case key clause clauses ...)))))

(define-syntax and
  (syntax-rules ()
    ((and) #t)
    ((and test) test)
    ((and test1 test2 ...)
     (if test1 (and test2 ...) #f))))

(define-syntax or
  (syntax-rules ()
    ((or) #f)
    ((or test) test)
    ((or test1 test2 ...)
     (let ((x test1))
       (if x x (or test2 ...))))))

(define-syntax when
  (syntax-rules ()
    ((when test result1 result2 ...)
     (if test
         (begin result1 result2 ...)))))

(define-syntax unless
  (syntax-rules ()
    ((unless test result1 result2 ...)
     (if (not test)
         (begin result1 result2 ...)))))

;; `let` と `letrec` は、互いを展開に使う。
(define-syntax let
  (syntax-rules ()
    ((let ((name val) ...) body1 body2 ...)
     ((lambda (name ...) body1 body2 ...)
      val ...))
    ((let tag ((name val) ...) body1 body2 ...)
     ((letrec ((tag (lambda (name ...)
                      body1 body2 ...)))
        tag)
      val ...))))

(define-syntax let*
  (syntax-rules ()
    ((let* () body1 body2 ...)
     (let () body1 body2 ...))
    ((let* ((name1 val1) (name2 val2) ...)
       body1 body2 ...)
     (let ((name1 val1))
       (let* ((name2 val2) ...)
         body1 body2 ...)))))

;; 原文との違いは3つある。
;; - 原文は、初期値の式の位置に `<undefined>` と書く。R7RS 4.2.2 は、`letrec` の変数が、
;;   初めは「不定の値を持つ新しい場所」に束縛されるとするので、`(if #f #f)` を置く。
;; - 原文は、本体を `set!` の後ろにそのまま置くので、本体の先頭の定義が「本体の先頭」でなくなる。
;;   R7RS 4.2.2 は、`letrec` の本体を定義で始めてよいとするので、`letrec*` と同じに、
;;   `(let () body ...)` で包む。
;; - 原文は、本体が0個の `letrec` を受け付ける。R7RS 4.2.2 は、本体に式が1つ以上を求める。
(define-syntax letrec
  (syntax-rules ()
    ((letrec ((var1 init1) ...) body1 body2 ...)
     (letrec "generate temp names"
       (var1 ...)
       ()
       ((var1 init1) ...)
       body1 body2 ...))
    ((letrec "generate temp names"
       ()
       (temp1 ...)
       ((var1 init1) ...)
       body ...)
     (let ((var1 (if #f #f)) ...)
       (let ((temp1 init1) ...)
         (set! var1 temp1)
         ...
         (let () body ...))))
    ((letrec "generate temp names"
       (x y ...)
       (temp ...)
       ((var1 init1) ...)
       body ...)
     (letrec "generate temp names"
       (y ...)
       (newtemp temp ...)
       ((var1 init1) ...)
       body ...))))

(define-syntax letrec*
  (syntax-rules ()
    ((letrec* ((var1 init1) ...) body1 body2 ...)
     (let ((var1 (if #f #f)) ...)
       (set! var1 init1)
       ...
       (let () body1 body2 ...)))))

;; 原文の `do` は、`(if #f #f)` で不定の値を得る。
(define-syntax do
  (syntax-rules ()
    ((do ((var init step ...) ...)
         (test expr ...)
         command ...)
     (letrec
         ((loop
           (lambda (var ...)
             (if test
                 (begin
                   (if #f #f)
                   expr ...)
                 (begin
                   command
                   ...
                   (loop (do "step" var step ...)
                         ...))))))
       (loop init ...)))
    ((do "step" x)
     x)
    ((do "step" x y)
     y)))

;; R7RS 7.3 は `quasiquote` の定義を与えない(「`quasiquote` を除いて」と書く)ので、
;; ここで書く。入れ子の深さは、`%quasiquote` の第2引数の、`#f` の並びの長さで数える。
;; 空は最も外側(unquote は評価される)で、`quasiquote` を1つ入れるたびに `#f` を
;; 1つ足し、`unquote` と `unquote-splicing` を1つ出るたびに1つ引く。
;;
;; ベクタは `(apply vector リスト)` で作る。`list->vector` は、ベクタのプリミティブを足す
;; 3e のあとにある。
(define-syntax quasiquote
  (syntax-rules ()
    ((quasiquote template)
     (%quasiquote template ()))))

(define-syntax %quasiquote
  (syntax-rules (quasiquote unquote unquote-splicing)
    ;; 最も外側の `unquote` は評価する。
    ((_ (unquote expr) ())
     expr)
    ;; 入れ子の中の `unquote` は、深さを1つ引いて、そのまま残す。
    ((_ (unquote expr) (level . levels))
     (list 'unquote (%quasiquote expr levels)))
    ;; リストの外の `unquote-splicing` は、最も外側では誤りである。
    ((_ (unquote-splicing expr) ())
     (syntax-error "unquote-splicing outside a list or a vector"))
    ((_ (unquote-splicing expr) (level . levels))
     (list 'unquote-splicing (%quasiquote expr levels)))
    ;; `quasiquote` は、深さを1つ足して、そのまま残す。
    ((_ (quasiquote template) levels)
     (list 'quasiquote (%quasiquote template (#f . levels))))
    ;; 要素の位置の `unquote-splicing`。最も外側では、リストを、残りの前に付ける。
    ((_ ((unquote-splicing expr) . rest) ())
     (append expr (%quasiquote rest ())))
    ((_ ((unquote-splicing expr) . rest) (level . levels))
     (cons (list 'unquote-splicing (%quasiquote expr levels))
           (%quasiquote rest (level . levels))))
    ((_ (first . rest) levels)
     (cons (%quasiquote first levels) (%quasiquote rest levels)))
    ((_ #(element ...) levels)
     (apply vector (%quasiquote (element ...) levels)))
    ((_ datum levels)
     'datum)))
