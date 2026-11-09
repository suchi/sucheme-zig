;;; 迷路の探索: 文字の盤面を、幅優先で S から G まで探し、最短の道を * で描く。
(import (scheme base) (scheme write))

(define maze
  (vector "#########"
          "#S..#...#"
          "#.#.#.#.#"
          "#.#...#.#"
          "#.#####.#"
          "#......G#"
          "#########"))

(define (cell r c) (string-ref (vector-ref maze r) c))

(define (find-char ch)
  (let loop ((r 0) (c 0))
    (cond ((= r (vector-length maze)) #f)
          ((= c (string-length (vector-ref maze r))) (loop (+ r 1) 0))
          ((char=? (cell r c) ch) (cons r c))
          (else (loop r (+ c 1))))))

(define start (find-char #\S))
(define goal (find-char #\G))

(define (neighbors p)
  (let ((r (car p)) (c (cdr p)))
    (let loop ((ds '((-1 . 0) (1 . 0) (0 . -1) (0 . 1))) (acc '()))
      (if (null? ds)
          (reverse acc)
          (let ((nr (+ r (car (car ds)))) (nc (+ c (cdr (car ds)))))
            (loop (cdr ds)
                  (if (char=? (cell nr nc) #\#)
                      acc
                      (cons (cons nr nc) acc))))))))

;; 幅優先探索。訪問済みの表は、各マスの直前のマスを持つ連想リスト。
(define (search)
  (let loop ((frontier (list start)) (came (list (cons start #f))))
    (cond ((null? frontier) #f)
          ((member goal (map car came)) came)
          (else
           (let inner ((cur frontier) (next '()) (came came))
             (if (null? cur)
                 (loop (reverse next) came)
                 (let add ((ns (neighbors (car cur))) (next next) (came came))
                   (cond ((null? ns) (inner (cdr cur) next came))
                         ((assoc (car ns) came) (add (cdr ns) next came))
                         (else (add (cdr ns)
                                    (cons (car ns) next)
                                    (append came (list (cons (car ns) (car cur))))))))))))))

(define (path came)
  (let loop ((p goal) (acc '()))
    (if p
        (loop (cdr (assoc p came)) (cons p acc))
        acc)))

(define came (search))
(define route (path came))
(display "steps: ")
(display (- (length route) 1))
(newline)

(do ((r 0 (+ r 1)))
    ((= r (vector-length maze)))
  (do ((c 0 (+ c 1)))
      ((= c (string-length (vector-ref maze r))))
    (let ((ch (cell r c)))
      (display (if (and (char=? ch #\.) (member (cons r c) route)) #\* ch))))
  (newline))
