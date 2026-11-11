;;; CSV の集計(ファイル版): 引数で渡された CSV のファイルを読み、分類ごとの件数と合計と
;;; 平均を出す。文字列ポートで入力を渡す `csv-totals.scm` の対で、同じデータなので、出力も
;;; 同じである。ファイルは `csv-totals-file.files/sales.csv` にある。
(import (scheme base) (scheme cxr) (scheme file) (scheme process-context) (scheme write))

;; 文字列を区切り文字で分ける。
(define (split str delimiter)
  (let loop ((chars (string->list str)) (current '()) (fields '()))
    (cond ((null? chars)
           (reverse (cons (list->string (reverse current)) fields)))
          ((char=? (car chars) delimiter)
           (loop (cdr chars) '() (cons (list->string (reverse current)) fields)))
          (else (loop (cdr chars) (cons (car chars) current) fields)))))

;; ポートから1行ずつ読み、欄のリストの列にする。
(define (read-rows port)
  (let loop ((rows '()))
    (let ((line (read-line port)))
      (if (eof-object? line)
          (reverse rows)
          (loop (cons (split line #\,) rows))))))

;; (分類 件数 合計) の連想リストを、最初に現れた順に作る。
(define (add-row! table row)
  (let ((entry (assoc (car row) table))
        (amount (string->number (caddr row))))
    (if entry
        (begin
          (set-car! (cdr entry) (+ (cadr entry) 1))
          (set-car! (cddr entry) (+ (caddr entry) amount))
          table)
        (append table (list (list (car row) 1 amount))))))

;; 最初の引数が、CSV のファイルのパスである。先頭の行は見出しなので、読み飛ばす。
(define path (cadr (command-line)))
(define rows (cdr (call-with-input-file path read-rows)))
(define table
  (let loop ((rows rows) (table '()))
    (if (null? rows)
        table
        (loop (cdr rows) (add-row! table (car rows))))))

(for-each
 (lambda (entry)
   (display (car entry))
   (display ": n=")
   (display (cadr entry))
   (display ", total ")
   (display (caddr entry))
   (display ", average ")
   (display (/ (caddr entry) (cadr entry)))
   (newline))
 table)

(display "all: n=")
(display (length rows))
(display ", total ")
(display (apply + (map caddr table)))
(newline)
