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

;; ここから下は、スライス 3i が足した派生構文である。R7RS 7.3 の定義を写し、
;; 変えた箇所は、それぞれの定義の注に書く。

;; `let-values` は、原文の定義をほぼそのまま写した。変えた箇所は1つで、本体を `begin` で
;; 包まず、式の並びのまま `"bind"` の規則に運んで、最後に `(let tmps body ...)` へ渡す。
;; 原文は `(begin body0 body1 ...)` で包むので、本体の先頭の定義(R7RS 4.2.2 が許す)が、
;; 本体の先頭でなくなる。
;; 初期値の式は外側の環境で評価し、束縛は一時変数 `x` に受けてから、まとめて `let` で
;; 利用者の名前に束縛する。`x` は規則ごとに展開が別の名前にするので、互いにも
;; 利用者の名前とも衝突しない。
(define-syntax let-values
  (syntax-rules ()
    ((let-values (binding ...) body0 body1 ...)
     (let-values "bind"
       (binding ...) () (body0 body1 ...)))
    ((let-values "bind" () tmps (body ...))
     (let tmps body ...))
    ((let-values "bind" ((b0 e0)
                         binding ...) tmps body)
     (let-values "mktmp" b0 e0 ()
       (binding ...) tmps body))
    ((let-values "mktmp" () e0 args
       bindings tmps body)
     (call-with-values
         (lambda () e0)
       (lambda args
         (let-values "bind"
           bindings tmps body))))
    ((let-values "mktmp" (a . b) e0 (arg ...)
       bindings (tmp ...) body)
     (let-values "mktmp" b e0 (arg ... x)
       bindings (tmp ... (a x)) body))
    ((let-values "mktmp" a e0 (arg ...)
       bindings (tmp ...) body)
     (call-with-values
         (lambda () e0)
       (lambda (arg ... . x)
         (let-values "bind"
           bindings (tmp ... (a x)) body))))))

(define-syntax let*-values
  (syntax-rules ()
    ((let*-values () body0 body1 ...)
     (let () body0 body1 ...))
    ((let*-values (binding0 binding1 ...)
       body0 body1 ...)
     (let-values (binding0)
       (let*-values (binding1 ...)
         body0 body1 ...)))))

;; `define-values` は、原文の定義の骨組み(最初の変数が、値のリストを一時的に持つ)を
;; 写した。原文との違いは2つある。
;; - 原文は、2個以上の変数のとき、値を `list` で受ける。個数が変数と合わなくても、
;;   余りは黙って捨てられ、不足は `cadr` の誤りになる。R7RS 5.3.3 は、仮引数と実引数の対応を
;;   `lambda` と同じにするので、値を受ける手続きの仮引数を利用者の変数にして、個数の
;;   検査を `lambda` の呼び出しに任せる。その手続きの中の変数は、`expr` を包む
;;   別の `lambda` の外にあるので、`expr` の評価には影響しない。
;; - 原文は、変数が0個のとき `dummy` を定義する。`dummy` は利用者の名前と衝突しうるので、
;;   `%` で始まる名前にした。ただし、マクロが導入した最上位の `define` は、別名を元の綴りに戻して
;;   表に束縛する(docs/design/frontend.md の解決規則の節。仮決めで、3q が直す)ので、最上位では
;;   `%define-values-dummy` が利用者の表に定義される。本体の中では別名のままで、衝突しない。
;; 本体の定義の位置で使えるのは、展開が `begin` に包んだ定義の並びで、本体の走査が
;; `begin` の中の定義を、本体の定義として扱うからである(src/syntax/expand.zig の `scanBody`)。
(define-syntax define-values
  (syntax-rules ()
    ((define-values () expr)
     (define %define-values-dummy
       (call-with-values (lambda () expr)
         (lambda () #f))))
    ((define-values (var) expr)
     (define var expr))
    ((define-values (var0 var1 ... varn) expr)
     (begin
       (define var0
         (call-with-values (lambda () expr)
           (lambda (var0 var1 ... varn)
             (list var0 var1 ... varn))))
       (define var1
         (let ((v (cadr var0)))
           (set-cdr! var0 (cddr var0))
           v))
       ...
       (define varn
         (let ((v (cadr var0)))
           (set! var0 (car var0))
           v))))
    ((define-values (var0 var1 ... . varn) expr)
     (begin
       (define var0
         (call-with-values (lambda () expr)
           (lambda (var0 var1 ... . varn)
             (apply list var0 var1 ... varn))))
       (define var1
         (let ((v (cadr var0)))
           (set-cdr! var0 (cddr var0))
           v))
       ...
       (define varn
         (let ((v (cdr var0)))
           (set! var0 (car var0))
           v))))
    ((define-values var expr)
     (define var
       (call-with-values (lambda () expr)
         list)))))

;; `case-lambda` は、原文の定義を写した。変えた箇所は、どの節にも合わないときの誤りに、
;; 渡された引数を添えたことだけである。原文は `(letrec-syntax ((cl (syntax-rules :::
;; ...)))` で、`...` を使う節の書き方と衝突しないよう、省略記号を `:::` にしている。
(define-syntax case-lambda
  (syntax-rules ()
    ((case-lambda (params body0 ...) ...)
     (lambda args
       (let ((len (length args)))
         (letrec-syntax
             ((cl (syntax-rules ::: ()
                    ((cl)
                     (error "no matching case-lambda clause for the arguments" args))
                    ((cl ((p :::) . body) . rest)
                     (if (= len (length '(p :::)))
                         (apply (lambda (p :::)
                                  . body)
                                args)
                         (cl . rest)))
                    ((cl ((p ::: . tail) . body)
                         . rest)
                     (if (>= len (length '(p :::)))
                         (apply
                          (lambda (p ::: . tail)
                            . body)
                          args)
                         (cl . rest))))))
           (cl (params body0 ...) ...)))))))

;; `guard` は、原文の定義を写した。補助のマクロの名前を `%guard-aux` にしたことと、
;; 節が0個の `(guard (e) body ...)` を受けることが、原文との違いである。節が0個のとき、
;; どの節の test も真にならないのと同じで、捕まえた値を `raise-continuable` で再送出する。
;; R7RS 4.2.7 の構文は `<cond clause>*` で、0個を許す。7.3 の定義は、この形に規則を持たない。
(define-syntax guard
  (syntax-rules ()
    ((guard (var clause ...) e1 e2 ...)
     ((call/cc
       (lambda (guard-k)
         (with-exception-handler
          (lambda (condition)
            ((call/cc
              (lambda (handler-k)
                (guard-k
                 (lambda ()
                   (let ((var condition))
                     (%guard-aux
                      (handler-k
                       (lambda ()
                         (raise-continuable condition)))
                      clause ...))))))))
          (lambda ()
            (call-with-values
                (lambda () e1 e2 ...)
              (lambda args
                (guard-k
                 (lambda ()
                   (apply values args)))))))))))))

(define-syntax %guard-aux
  (syntax-rules (else =>)
    ((_ reraise)
     reraise)
    ((_ reraise (else result1 result2 ...))
     (begin result1 result2 ...))
    ((_ reraise (test => result))
     (let ((temp test))
       (if temp
           (result temp)
           reraise)))
    ((_ reraise (test => result)
        clause1 clause2 ...)
     (let ((temp test))
       (if temp
           (result temp)
           (%guard-aux reraise clause1 clause2 ...))))
    ((_ reraise (test))
     (or test reraise))
    ((_ reraise (test) clause1 clause2 ...)
     (let ((temp test))
       (if temp
           temp
           (%guard-aux reraise clause1 clause2 ...))))
    ((_ reraise (test result1 result2 ...))
     (if test
         (begin result1 result2 ...)
         reraise))
    ((_ reraise
        (test result1 result2 ...)
        clause1 clause2 ...)
     (if test
         (begin result1 result2 ...)
         (%guard-aux reraise clause1 clause2 ...)))))

;; `define-record-type`(R7RS 5.5)。7.3 は定義を与えないので、ここで書く。
;; 型は `%make-record-type`(src/prim/record.zig)で作って、利用者の `<name>` に束縛する。
;; 展開は、利用者の名前だけを定義し、補助の最上位の名前を導入しない
;; (マクロが導入した最上位の定義は、利用者の同じ綴りの変数を書き換えうるため。上の
;; `define-values` の注を参照)。
;;
;; フィールドの添字は、展開の時点ではなく、定義を評価するときに、フィールド名のシンボルの
;; リスト(`'(fname ...)`)から求める。`syntax-rules` は2つの識別子が同じ綴りかを比べられない
;; ので、構文の上で添字を求めると、コンストラクタの引数とフィールドの対応が書けない。
;; クォートは、識別子を元のシンボルに戻す。生成する手続きは、添字を閉じ込めるので、
;; 呼び出しのたびに探索しない。コンストラクタだけは、フィールドの並びと引数の並びが
;; 違うとき、呼び出しのたびに並べ替える。
;;
;; コンストラクタが受けないフィールドの初期値は、不定の値(`(if #f #f)`)である(R7RS 5.5)。
(define-syntax define-record-type
  (syntax-rules ()
    ((define-record-type type
       (constructor constructor-field ...)
       predicate
       (field-name field-spec ...)
       ...)
     (begin
       (define type
         (%make-record-type 'type (length '(field-name ...))))
       (define constructor
         (%record-constructor type '(field-name ...) '(constructor-field ...)))
       (define predicate
         (%record-predicate type))
       (%define-record-fields type (field-name ...)
         ((field-name field-spec ...) ...))))))

;; 全フィールド名のリスト `fields` を、1つのパターン変数で受ける。`syntax-rules` は、
;; 省略記号の中で、同じ変数をもう一度省略記号つきで使えない。
(define-syntax %define-record-fields
  (syntax-rules ()
    ((_ type fields (spec ...))
     (begin
       (%define-record-field type 'fields spec)
       ...))))

(define-syntax %define-record-field
  (syntax-rules ()
    ((_ type fields (field-name accessor))
     (define accessor
       (%record-accessor type fields 'field-name 'accessor)))
    ((_ type fields (field-name accessor modifier))
     (begin
       (define accessor
         (%record-accessor type fields 'field-name 'accessor))
       (define modifier
         (%record-modifier type fields 'field-name 'modifier))))
    ((_ type fields bad)
     (syntax-error "define-record-type: a field is (name accessor) or (name accessor modifier)" bad))))

;; 述語は、型の値を閉じ込める。式の中で `type` の名前を引くと、利用者が後でその名前を
;; 書き換えたときに、判定が変わる。
(define (%record-predicate type)
  (lambda (object)
    (%record? object type)))

;; `name` の `fields` での添字。`k` は、`fields` の先頭の添字。
(define (%field-index name fields k)
  (if (null? fields)
      (error "define-record-type: not a field of the record type" name)
      (if (eq? name (car fields))
          k
          (%field-index name (cdr fields) (+ k 1)))))

(define (%record-accessor type fields name accessor)
  (let ((index (%field-index name fields 0)))
    (lambda (record)
      (if (%record? record type)
          (%record-ref record type index)
          (error "wrong type of argument to a record accessor" accessor record)))))

(define (%record-modifier type fields name modifier)
  (let ((index (%field-index name fields 0)))
    (lambda (record value)
      (if (%record? record type)
          (%record-set! record type index value)
          (error "wrong type of argument to a record modifier" modifier record)))))

;; `fields` の各フィールドが、コンストラクタの引数の何番目か(無ければ `#f`)のリスト。
;; コンストラクタの引数に、`fields` に無い名前があれば、誤りにする。
(define (%constructor-positions fields constructor-fields)
  (%check-constructor-fields fields constructor-fields)
  (%positions fields constructor-fields))

(define (%check-constructor-fields fields constructor-fields)
  (if (pair? constructor-fields)
      (begin
        (%field-index (car constructor-fields) fields 0)
        (%check-constructor-fields fields (cdr constructor-fields)))))

(define (%positions fields constructor-fields)
  (if (null? fields)
      '()
      (cons (%position (car fields) constructor-fields 0)
            (%positions (cdr fields) constructor-fields))))

(define (%position name names k)
  (if (null? names)
      #f
      (if (eq? name (car names))
          k
          (%position name (cdr names) (+ k 1)))))

;; 引数のリスト `args` から、`positions` の順に、レコードのフィールドの値を並べる。
(define (%arrange positions args)
  (if (null? positions)
      '()
      (cons (if (car positions)
                (list-ref args (car positions))
                (if #f #f))
            (%arrange (cdr positions) args))))

(define (%record-constructor type fields constructor-fields)
  (let ((positions (%constructor-positions fields constructor-fields))
        (count (length constructor-fields)))
    (if (equal? fields constructor-fields)
        (lambda args
          (if (= (length args) count)
              (apply %make-record type args)
              (error "wrong number of arguments to a record constructor" (length args))))
        (lambda args
          (if (= (length args) count)
              (apply %make-record type (%arrange positions args))
              (error "wrong number of arguments to a record constructor" (length args)))))))

;; R7RS 7.3 の `delay-force` と `delay`(スライス 3j)。約束の内部の作り方 `%make-promise`
;; (src/prim/promise.zig)は、強制済みかの印と、値か手続きを取る。`delay` は、7.3 の定義どおり、
;; `delay-force` に、すでに強制済みの約束を返す式を渡す形に展開する。連鎖した `delay-force` が
;; 一定の空間で終わることは、`force` の機械操作(docs/design/runtime.md の「EOF の値と約束」)が保つ。
(define-syntax delay-force
  (syntax-rules ()
    ((delay-force expression)
     (%make-promise #f (lambda () expression)))))

(define-syntax delay
  (syntax-rules ()
    ((delay expression)
     (delay-force (%make-promise #t expression)))))

