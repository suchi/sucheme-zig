;; R7RS 6.4 のリストの手続きと、6.1 の `boolean=?`。`(sucheme core)` の特殊形式と
;; プリミティブの上に、`define` と `lambda` と `if` だけで書く(派生構文は 3h が足す)。
;; 原文はこの環境から取得できないので、定義は記憶に基づく(未確認)。
;;
;; `map` と `for-each` を Scheme で書くのは、末尾呼び出しと継続の再入が、機械の
;; 規則からそのまま正しくなるためである(docs/adr/0006-library-system-and-scheme-level-stdlib.md)。
;; `map` は結果を逆順に積んでから、破壊せずに逆にして返す。破壊的に作ると、継続を
;; 再入したときに、前に返した結果のリストが書き換わる(R7RS 6.10 が禁じている)。
;;
;; `%` で始まる名前は、このファイルの中だけで使う内部用の名前で、エクスポートしない。

;; 省略できる引数の並び `rest` から、1個の値を取り出す。無ければ `default`。2個以上は誤り。
(define (%optional name rest default)
  (if (null? rest)
      default
      (if (null? (cdr rest))
          (car rest)
          (error "too many arguments to" name))))

;; `acc` を逆順にして、`tail` の前に付ける。
(define (%reverse-onto acc tail)
  (if (null? acc)
      tail
      (%reverse-onto (cdr acc) (cons (car acc) tail))))

(define (%reverse l acc whole)
  (if (pair? l)
      (%reverse (cdr l) (cons (car l) acc) whole)
      (if (null? l)
          acc
          (error "wrong type of argument to reverse" whole))))

(define (reverse l)
  (%reverse l '() l))

(define (%append-all lists)
  (if (null? (cdr lists))
      (car lists)
      (%reverse-onto (reverse (car lists)) (%append-all (cdr lists)))))

(define (append . lists)
  (if (null? lists)
      '()
      (%append-all lists)))

;; `k` 個の cdr を辿る。足りなければ `message` で誤りにする。
(define (%tail l k whole whole-k message)
  (if (< k 0)
      (error message whole whole-k)
      (if (= k 0)
          l
          (if (pair? l)
              (%tail (cdr l) (- k 1) whole whole-k message)
              (error message whole whole-k)))))

(define (list-tail l k)
  (%tail l k l k "argument out of range in list-tail"))

;; 指す先がペアでなければ、`message` で誤りにする。
(define (%pair-at l k message)
  (%must-pair (%tail l k l k message) l k message))

(define (%must-pair p whole whole-k message)
  (if (pair? p)
      p
      (error message whole whole-k)))

(define (list-ref l k)
  (car (%pair-at l k "argument out of range in list-ref")))

(define (list-set! l k obj)
  (set-car! (%pair-at l k "argument out of range in list-set!") obj))

(define (%copy l acc)
  (if (pair? l)
      (%copy (cdr l) (cons (car l) acc))
      (%reverse-onto acc l)))

(define (list-copy l)
  (%copy l '()))

(define (%fill k fill acc)
  (if (= k 0)
      acc
      (%fill (- k 1) fill (cons fill acc))))

(define (make-list k . rest)
  (if (< k 0)
      (error "argument out of range in make-list" k)
      (%fill k (%optional 'make-list rest (if #f #f)) '())))

(define (memq x l)
  (if (pair? l)
      (if (eq? x (car l))
          l
          (memq x (cdr l)))
      (if (null? l)
          #f
          (error "wrong type of argument to memq" l))))

(define (memv x l)
  (if (pair? l)
      (if (eqv? x (car l))
          l
          (memv x (cdr l)))
      (if (null? l)
          #f
          (error "wrong type of argument to memv" l))))

(define (%member x l same?)
  (if (pair? l)
      (if (same? x (car l))
          l
          (%member x (cdr l) same?))
      (if (null? l)
          #f
          (error "wrong type of argument to member" l))))

(define (member x l . rest)
  (%member x l (%optional 'member rest equal?)))

(define (assq x alist)
  (if (pair? alist)
      (if (pair? (car alist))
          (if (eq? x (car (car alist)))
              (car alist)
              (assq x (cdr alist)))
          (error "wrong type of argument to assq" (car alist)))
      (if (null? alist)
          #f
          (error "wrong type of argument to assq" alist))))

(define (assv x alist)
  (if (pair? alist)
      (if (pair? (car alist))
          (if (eqv? x (car (car alist)))
              (car alist)
              (assv x (cdr alist)))
          (error "wrong type of argument to assv" (car alist)))
      (if (null? alist)
          #f
          (error "wrong type of argument to assv" alist))))

(define (%assoc x alist same?)
  (if (pair? alist)
      (if (pair? (car alist))
          (if (same? x (car (car alist)))
              (car alist)
              (%assoc x (cdr alist) same?))
          (error "wrong type of argument to assoc" (car alist)))
      (if (null? alist)
          #f
          (error "wrong type of argument to assoc" alist))))

(define (assoc x alist . rest)
  (%assoc x alist (%optional 'assoc rest equal?)))

(define (caar x) (car (car x)))
(define (cadr x) (car (cdr x)))
(define (cdar x) (cdr (car x)))
(define (cddr x) (cdr (cdr x)))

(define (%all-booleans? args)
  (if (null? args)
      #t
      (if (boolean? (car args))
          (%all-booleans? (cdr args))
          (error "wrong type of argument to boolean=?" (car args)))))

(define (%all-same? first args)
  (if (null? args)
      #t
      (if (eq? first (car args))
          (%all-same? first (cdr args))
          #f)))

(define (boolean=? a b . rest)
  (%all-booleans? (cons a (cons b rest)))
  (if (eq? a b)
      (%all-same? a rest)
      #f))

;; 複数のリスト `lists` を取る `map` と `for-each` は、どれかが空になったところで終わる
;; (R7RS 6.10)。空のものが無いのに、ペアでないものがあれば、不正なリストとして誤りにする。
(define (%any-null? lists)
  (if (null? lists)
      #f
      (if (null? (car lists))
          #t
          (%any-null? (cdr lists)))))

(define (%check-pairs lists name)
  (if (null? lists)
      #t
      (if (pair? (car lists))
          (%check-pairs (cdr lists) name)
          (error name (car lists)))))

(define (%cars lists)
  (if (null? lists)
      '()
      (cons (car (car lists)) (%cars (cdr lists)))))

(define (%cdrs lists)
  (if (null? lists)
      '()
      (cons (cdr (car lists)) (%cdrs (cdr lists)))))

(define (%map1 f l acc whole)
  (if (pair? l)
      (%map1 f (cdr l) (cons (f (car l)) acc) whole)
      (if (null? l)
          (reverse acc)
          (error "wrong type of argument to map" whole))))

(define (%mapn f lists acc)
  (if (%any-null? lists)
      (reverse acc)
      (begin
        (%check-pairs lists "wrong type of argument to map")
        (%mapn f (%cdrs lists) (cons (apply f (%cars lists)) acc)))))

(define (map f l . more)
  (if (null? more)
      (%map1 f l '() l)
      (%mapn f (cons l more) '())))

(define (%for-each1 f l whole)
  (if (pair? l)
      (begin
        (f (car l))
        (%for-each1 f (cdr l) whole))
      (if (null? l)
          (if #f #f)
          (error "wrong type of argument to for-each" whole))))

(define (%for-eachn f lists)
  (if (%any-null? lists)
      (if #f #f)
      (begin
        (%check-pairs lists "wrong type of argument to for-each")
        (apply f (%cars lists))
        (%for-eachn f (%cdrs lists)))))

(define (for-each f l . more)
  (if (null? more)
      (%for-each1 f l l)
      (%for-eachn f (cons l more))))
