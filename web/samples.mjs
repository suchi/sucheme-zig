// The sample programs offered in the page, as `{ id, title, source }`.
//
// 選ぶと入力欄に入る(実行はしない)。ソースは、いまの WASM で評価できるものに限り、
// 値の出力(`display` は段階5)だけで結果が見える形にする。どのサンプルも評価できて、
// 期待する出力になることは、tools/test-wasm/main.mjs が確かめる。

export const samples = [
  {
    id: "factorial",
    title: "階乗",
    source: `(define (fact n)
  (if (= n 0)
      1
      (* n (fact (- n 1)))))
(fact 10)`,
  },
  {
    id: "tail-loop",
    title: "末尾再帰のループ",
    source: `; 末尾呼び出しは、深さに関係なく一定の空間で進む。
(define (sum n acc)
  (if (= n 0)
      acc
      (sum (- n 1) (+ acc n))))
(sum 100000 0)`,
  },
  {
    id: "counter",
    title: "クロージャのカウンタ",
    source: `(define (make-counter)
  (let ((n 0))
    (lambda ()
      (set! n (+ n 1))
      n)))
(define a (make-counter))
(define b (make-counter))
(a)
(a)
(b)
(a)`,
  },
  {
    id: "lists",
    title: "リストの操作",
    source: `(define xs '(3 1 2))
(map (lambda (x) (* x x)) xs)
(append xs '(4 5))
(reverse xs)
(assq 'b '((a 1) (b 2) (c 3)))
(list-tail xs 1)`,
  },
  {
    id: "record",
    title: "レコード",
    source: `(define-record-type point
  (make-point x y)
  point?
  (x point-x)
  (y point-y set-point-y!))
(define p (make-point 3 4))
(point-x p)
(set-point-y! p 10)
(point-y p)
(point? p)
(point? 5)`,
  },
  {
    id: "escape",
    title: "脱出と例外",
    source: `; call/cc で、残りの計算を捨てて抜ける。
(call/cc (lambda (return)
  (+ 1 (return 42))))

(define (find-first pred lst)
  (call/cc (lambda (return)
    (for-each (lambda (x) (if (pred x) (return x))) lst)
    #f)))
(find-first (lambda (x) (> x 3)) '(1 3 4 5))

; guard で、送出された誤りを受ける。
(guard (e (#t (error-object-message e)))
  (error "boom" 1 2))`,
  },
  {
    id: "numeric-tower",
    title: "数値塔(多倍長整数と有理数)",
    source: `(import (scheme base) (scheme inexact))
; 整数は桁あふれせず、割り算は正確な有理数になる。
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 30)
(expt 2 100)
(/ 1 3)
(+ (/ 1 3) (/ 1 6))
(inexact (/ 1 3))
(sqrt 16)
(sqrt 2)`,
  },
  {
    id: "strings",
    title: "文字列と文字",
    source: `(import (scheme base) (scheme char))
(string-append "Scheme" " " "λ")
(string-upcase "hello")
(string-length "こんにちは")
(list->string (reverse (string->list "abc")))
(substring "hello world" 6 11)
(string<? "apple" "banana")
(string->number "1e3")
(string->symbol "foo")`,
  },
  {
    id: "string-ports",
    title: "文字列ポート",
    source: `(import (scheme base) (scheme read) (scheme write))
; 出力ポートに書いた内容を文字列として取り出す。
(define out (open-output-string))
(write 'sym out)
(write-string " and " out)
(write "text" out)
(get-output-string out)

; 入力ポートから、データを1つずつ読む。
(define in (open-input-string "(a b) 42 \\"s\\""))
(read in)
(read in)
(read in)
(eof-object? (read in))`,
  },
  {
    id: "dynamic-wind",
    title: "dynamic-wind と脱出",
    source: `; 脱出しても、after の手続きが呼ばれる。
(define trace '())
(define (note x) (set! trace (cons x trace)))
(call/cc (lambda (k)
  (dynamic-wind
    (lambda () (note 'in))
    (lambda () (note 'body) (k 'escaped) (note 'unreachable))
    (lambda () (note 'out)))))
(reverse trace)`,
  },
  {
    id: "library",
    title: "ライブラリの定義",
    source: `(define-library (example stack)
  (export make-stack push! pop!)
  (import (scheme base))
  (begin
    (define (make-stack) (list '()))
    (define (push! s x) (set-car! s (cons x (car s))))
    (define (pop! s)
      (let ((x (caar s)))
        (set-car! s (cdar s))
        x))))
(import (scheme base) (example stack))
(define s (make-stack))
(push! s 1)
(push! s 2)
(pop! s)
(pop! s)`,
  },
];
