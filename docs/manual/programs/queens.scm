;;; 8 クイーン: 8 x 8 の盤面に、互いに取り合わない 8 つのクイーンを置く。
(import (scheme base) (scheme write))

;; 置いた列の位置を、新しい行から古い行の順にリストで持つ。
;; 新しいクイーンを col に置けるかを、置いてある行ごとの距離で調べる。
(define (safe? col placed)
  (let loop ((rest placed) (distance 1))
    (cond ((null? rest) #t)
          ((or (= (car rest) col)
               (= (abs (- (car rest) col)) distance))
           #f)
          (else (loop (cdr rest) (+ distance 1))))))

(define (queens n)
  (let place ((row 0) (placed '()))
    (if (= row n)
        (list (reverse placed))
        (let try ((col 0))
          (cond ((= col n) '())
                ((safe? col placed)
                 (append (place (+ row 1) (cons col placed))
                         (try (+ col 1))))
                (else (try (+ col 1))))))))

(define solutions (queens 8))
(display (length solutions))
(display " solutions")
(newline)
(display "first: ")
(display (car solutions))
(newline)

;; 盤面として描く。
(define (draw solution)
  (for-each
   (lambda (col)
     (do ((i 0 (+ i 1)))
         ((= i 8))
       (display (if (= i col) "Q" ".")))
     (newline))
   solution))
(draw (car solutions))

(display (map (lambda (n) (length (queens n))) '(1 2 3 4 5 6)))
(newline)
