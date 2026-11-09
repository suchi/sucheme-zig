;;; 単語の数え上げ: 文字列ポートから1文字ずつ読み、単語に分けて数える。
(import (scheme base) (scheme char) (scheme write))

(define text "the quick brown fox jumps over the lazy dog. The dog sleeps; the fox runs.")

;; 英字以外を区切りとみなし、小文字にそろえた単語のリストを返す。
(define (words str)
  (let ((in (open-input-string str)))
    (let loop ((current '()) (acc '()))
      (let ((c (read-char in)))
        (cond ((eof-object? c)
               (reverse (if (null? current)
                            acc
                            (cons (list->string (reverse current)) acc))))
              ((char-alphabetic? c)
               (loop (cons (char-downcase c) current) acc))
              ((null? current) (loop '() acc))
              (else (loop '() (cons (list->string (reverse current)) acc))))))))

;; (単語 . 回数) の連想リストに1語を足す。
(define (count-word counts w)
  (let ((entry (assoc w counts)))
    (if entry
        (begin (set-cdr! entry (+ (cdr entry) 1)) counts)
        (cons (cons w 1) counts))))

(define ws (words text))
(display (length ws))
(display " words")
(newline)

(define (count-all ws)
  (let loop ((ws ws) (counts '()))
    (if (null? ws)
        counts
        (loop (cdr ws) (count-word counts (car ws))))))

;; 回数の多い順、同じなら単語の辞書順に並べる。挿入ソートで足りる大きさ。
(define (before? a b)
  (or (> (cdr a) (cdr b))
      (and (= (cdr a) (cdr b)) (string<? (car a) (car b)))))

(define (insert x sorted)
  (cond ((null? sorted) (list x))
        ((before? x (car sorted)) (cons x sorted))
        (else (cons (car sorted) (insert x (cdr sorted))))))

(define (sort-counts counts)
  (let loop ((rest counts) (sorted '()))
    (if (null? rest)
        sorted
        (loop (cdr rest) (insert (car rest) sorted)))))

(define sorted (sort-counts (count-all ws)))
(for-each
 (lambda (entry)
   (display (car entry))
   (display " ")
   (display (cdr entry))
   (newline))
 sorted)
(display (length sorted))
(display " distinct")
(newline)
