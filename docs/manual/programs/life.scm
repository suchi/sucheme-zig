;;; ライフゲーム: グライダーを 4 世代進めると、1 マス斜めに動く。
(import (scheme base) (scheme write))

(define size 6)

;; 盤面は、行ごとのベクタのベクタ。外側は死んだマスとして扱う。
(define (new-board)
  (let ((board (make-vector size #f)))
    (do ((r 0 (+ r 1)))
        ((= r size) board)
      (vector-set! board r (make-vector size 0)))))

(define (cell board r c)
  (if (and (>= r 0) (< r size) (>= c 0) (< c size))
      (vector-ref (vector-ref board r) c)
      0))

(define (neighbors board r c)
  (let loop ((dr -1) (dc -1) (sum 0))
    (cond ((> dr 1) sum)
          ((> dc 1) (loop (+ dr 1) -1 sum))
          ((and (= dr 0) (= dc 0)) (loop dr (+ dc 1) sum))
          (else (loop dr (+ dc 1) (+ sum (cell board (+ r dr) (+ c dc))))))))

(define (step board)
  (let ((next (new-board)))
    (do ((r 0 (+ r 1)))
        ((= r size) next)
      (do ((c 0 (+ c 1)))
          ((= c size))
        (let ((n (neighbors board r c))
              (alive (= (cell board r c) 1)))
          (vector-set! (vector-ref next r) c
                       (if (or (= n 3) (and alive (= n 2))) 1 0)))))))

(define (draw board)
  (do ((r 0 (+ r 1)))
      ((= r size))
    (do ((c 0 (+ c 1)))
        ((= c size))
      (display (if (= (cell board r c) 1) "#" ".")))
    (newline)))

(define glider (new-board))
(for-each (lambda (p) (vector-set! (vector-ref glider (car p)) (cdr p) 1))
          '((0 . 1) (1 . 2) (2 . 0) (2 . 1) (2 . 2)))

(define (run board generations)
  (if (= generations 0)
      board
      (run (step board) (- generations 1))))

(display "generation 0") (newline)
(draw glider)
(display "generation 4") (newline)
(draw (run glider 4))
