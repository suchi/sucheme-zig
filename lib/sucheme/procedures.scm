;; R7RS 6.4 のリストの手続きと、6.1 の `boolean=?`。`(sucheme core)` の特殊形式と
;; プリミティブの上に、`define` と `lambda` と `if` だけで書く(派生構文は 3h が足す)。
;; 定義は、R7RS 6.1 と 6.4 と 6.10 の原文(docs/spec/)で確かめた。`member` と `assoc` の第3引数は、
;; 原文が呼び出しの引数の順を定めていないので、慣例に倣って `(compare x elem)` の順にした。
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

;; R7RS 6.8 と 6.7 の高階手続き(スライス 3j)。
;;
;; `vector-map` は、結果を専用のベクタに書いてから、複製して返す。継続を再入すると、
;; 前に返した結果が書き換わる(R7RS 6.8 が禁じている)ので、返すのは常に新しい複製である。
;; 引数が複数のときは、一番短いベクタの長さで止まる。`vector-for-each` は、添字で進む。
;; 文字列の手続きは、リストに直して `map` と `for-each` に渡す。`map` が再入に対して
;; 正しいので、文字列の側も正しくなる。`string-map` の手続きは文字を返す(`list->string` が検査する)。

(define (%check-vectors vs name)
  (if (null? vs)
      #t
      (if (vector? (car vs))
          (%check-vectors (cdr vs) name)
          (error name (car vs)))))

(define (%check-strings ss name)
  (if (null? ss)
      #t
      (if (string? (car ss))
          (%check-strings (cdr ss) name)
          (error name (car ss)))))

;; ベクタの並び `vs` の長さの最小値。
(define (%min-vector-length vs)
  (if (null? (cdr vs))
      (vector-length (car vs))
      (%min (vector-length (car vs)) (%min-vector-length (cdr vs)))))

(define (%min a b)
  (if (< a b) a b))

;; ベクタの並び `vs` の `i` 番目の要素のリスト。
(define (%vector-refs vs i)
  (if (null? vs)
      '()
      (cons (vector-ref (car vs) i) (%vector-refs (cdr vs) i))))

(define (%string-lists ss)
  (if (null? ss)
      '()
      (cons (string->list (car ss)) (%string-lists (cdr ss)))))

(define (%vector-map1 f v result i n)
  (if (< i n)
      (begin
        (vector-set! result i (f (vector-ref v i)))
        (%vector-map1 f v result (+ i 1) n))
      (vector-copy result)))

(define (%vector-mapn f vs result i n)
  (if (< i n)
      (begin
        (vector-set! result i (apply f (%vector-refs vs i)))
        (%vector-mapn f vs result (+ i 1) n))
      (vector-copy result)))

(define (vector-map f v . more)
  (if (null? more)
      (begin
        (%check-vectors (list v) "wrong type of argument to vector-map")
        (%vector-map1 f v (make-vector (vector-length v)) 0 (vector-length v)))
      (begin
        (%check-vectors (cons v more) "wrong type of argument to vector-map")
        (%vector-map-all f (cons v more)))))

(define (%vector-map-all f vs)
  (%vector-mapn f vs (make-vector (%min-vector-length vs)) 0 (%min-vector-length vs)))

(define (%vector-for-each1 f v i)
  (if (< i (vector-length v))
      (begin
        (f (vector-ref v i))
        (%vector-for-each1 f v (+ i 1)))
      (if #f #f)))

(define (%vector-for-eachn f vs i n)
  (if (< i n)
      (begin
        (apply f (%vector-refs vs i))
        (%vector-for-eachn f vs (+ i 1) n))
      (if #f #f)))

(define (vector-for-each f v . more)
  (if (null? more)
      (begin
        (%check-vectors (list v) "wrong type of argument to vector-for-each")
        (%vector-for-each1 f v 0))
      (begin
        (%check-vectors (cons v more) "wrong type of argument to vector-for-each")
        (%vector-for-eachn f (cons v more) 0 (%min-vector-length (cons v more))))))

;; `string-map` の手続きが返した値の並び `l` が、すべて文字であることを検査する。
(define (%check-chars l name)
  (if (null? l)
      #t
      (if (char? (car l))
          (%check-chars (cdr l) name)
          (error name (car l)))))

(define (%string-map-result l)
  (%check-chars l "wrong type of argument to string-map")
  (list->string l))

(define (string-map f s . more)
  (%check-strings (cons s more) "wrong type of argument to string-map")
  (%string-map-result (apply map f (%string-lists (cons s more)))))

(define (string-for-each f s . more)
  (%check-strings (cons s more) "wrong type of argument to string-for-each")
  (apply for-each f (%string-lists (cons s more))))

;; R7RS 6.2.6 の整数の手続きのうち、数値塔を要らないもの(スライス 3s)。`quotient`
;; `remainder` `modulo` と比較の上に書く。今の数は固定長の整数だけなので、定義は整数の
;; ものである。段階4で不正確な数が入ったら、不正確な数の扱いを足す。定義と例は、
;; R7RS 6.2.6 の原文(docs/spec/)で確かめた。
;; 引数の型の誤りは、内側で呼ぶプリミティブ(`<` や `remainder`)の名前で報告される。
;; ただし、結果が先に決まる引数の組(`(lcm 0 'a)` は 0)では、残りの引数を確かめない。

(define (zero? z) (= z 0))
(define (positive? x) (> x 0))
(define (negative? x) (< x 0))
(define (even? n) (= (remainder n 2) 0))
(define (odd? n) (not (even? n)))
(define (abs x) (if (< x 0) (- x) x))
(define (square z) (* z z))

;; floor の商と余りは、余りが割る数と同じ符号になる(`modulo` と同じ)。商は、切り捨ての
;; 商から、割り切れず余りと割る数の符号が異なるときに1を引く。余りを引いてから割る形は、
;; 結果が固定長の整数に収まるのに、引き算があふれる(`(floor-quotient <最小の負の数> 3)`)。
(define (%floor-adjust q r n2)
  (if (= r 0)
      q
      (if (< r 0)
          (if (< n2 0) q (- q 1))
          (if (< n2 0) (- q 1) q))))
(define (floor-remainder n1 n2) (modulo n1 n2))
(define (floor-quotient n1 n2) (%floor-adjust (quotient n1 n2) (remainder n1 n2) n2))
(define (floor/ n1 n2) (values (floor-quotient n1 n2) (modulo n1 n2)))

(define (truncate-quotient n1 n2) (quotient n1 n2))
(define (truncate-remainder n1 n2) (remainder n1 n2))
(define (truncate/ n1 n2) (values (quotient n1 n2) (remainder n1 n2)))

(define (%gcd2 a b)
  (if (= b 0)
      (abs a)
      (%gcd2 b (remainder a b))))

(define (%gcd-all acc ns)
  (if (null? ns)
      acc
      (%gcd-all (%gcd2 acc (car ns)) (cdr ns))))

;; 引数が無ければ、0(gcd の単位元)である。最初の引数を初期値にして、絶対値は最後に取る。
;; 0 を初期値にすると、最初の引数の絶対値を先に取り、最小の負の数であふれる。
(define (gcd . ns)
  (if (null? ns)
      0
      (abs (%gcd-all (car ns) (cdr ns)))))

(define (%lcm2 a b)
  (if (= a 0)
      0
      (if (= b 0)
          0
          (abs (* (quotient a (%gcd2 a b)) b)))))

(define (%lcm-all acc ns)
  (if (null? ns)
      acc
      (%lcm-all (%lcm2 acc (car ns)) (cdr ns))))

;; 引数が無ければ、1(lcm の単位元)である。
(define (lcm . ns) (%lcm-all 1 ns))

