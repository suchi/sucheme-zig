;;; 処理時間の計測: `current-jiffy` の差を秒に直して、2つの実装の時間を比べる。
;;; 時間の値は実行のたびに変わるので、出力には載せない。出すのは、結果と、
;;; 時間の性質(差が 0 以上の正確な数であること)だけである。
(import (scheme base) (scheme write) (scheme time))

;; thunk を呼び、(結果 . かかった秒数) を返す。秒数は正確な有理数である。
(define (timed thunk)
  (let* ((start (current-jiffy))
         (result (thunk))
         (end (current-jiffy)))
    (cons result (/ (- end start) (jiffies-per-second)))))

;; 同じ値を求める2つの実装。
(define (sum-recursive n)
  (if (= n 0) 0 (+ n (sum-recursive (- n 1)))))

(define (sum-iterative n)
  (let loop ((i 1) (acc 0))
    (if (> i n) acc (loop (+ i 1) (+ acc i)))))

(define a (timed (lambda () (sum-recursive 5000))))
(define b (timed (lambda () (sum-iterative 5000))))

(display "recursive: ")
(display (car a))
(newline)
(display "iterative: ")
(display (car b))
(newline)
(display "same result: ")
(display (= (car a) (car b)))
(newline)
(display "times are exact and non-negative: ")
(display (and (exact? (cdr a)) (>= (cdr a) 0)
              (exact? (cdr b)) (>= (cdr b) 0)))
(newline)

;; 1回の測定は揺れるので、何回か測った最小値を使うことが多い。
(define (best-of n thunk)
  (let loop ((i 0) (best #f))
    (if (= i n)
        best
        (let ((t (cdr (timed thunk))))
          (loop (+ i 1) (if (or (not best) (< t best)) t best))))))

(display "best of 5 is non-negative: ")
(display (>= (best-of 5 (lambda () (sum-iterative 1000))) 0))
(newline)

;; 1秒あたりのジフィーの数は、正の整数である。
(display "jiffies per second is a positive integer: ")
(display (and (exact? (jiffies-per-second))
              (integer? (jiffies-per-second))
              (> (jiffies-per-second) 0)))
(newline)
