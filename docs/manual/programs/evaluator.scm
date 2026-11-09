;;; 小さな式の評価器: 数、変数、算術、if、let、lambda、手続きの適用だけを持つ。
(import (scheme base) (scheme cxr) (scheme write))

;; 環境は (名前 . 値) の連想リスト。手続きはクロージャを表すリストで持つ。
(define (lookup name env)
  (let ((hit (assq name env)))
    (if hit (cdr hit) (error "unbound variable" name))))

(define (extend env names values)
  (append (map cons names values) env))

(define primitives
  (list (cons '+ +) (cons '- -) (cons '* *) (cons '< <) (cons '= =)))

(define (evaluate e env)
  (cond ((number? e) e)
        ((boolean? e) e)
        ((symbol? e) (lookup e env))
        (else
         (case (car e)
           ((quote) (cadr e))
           ((if)
            (if (evaluate (cadr e) env)
                (evaluate (caddr e) env)
                (evaluate (cadddr e) env)))
           ((let)
            (let ((names (map car (cadr e)))
                  (vals (map (lambda (b) (evaluate (cadr b) env)) (cadr e))))
              (evaluate (caddr e) (extend env names vals))))
           ((lambda) (list 'closure (cadr e) (caddr e) env))
           (else
            (apply-proc (evaluate (car e) env)
                        (map (lambda (a) (evaluate a env)) (cdr e))))))))

(define (apply-proc f args)
  (if (procedure? f)
      (apply f args)
      (evaluate (caddr f) (extend (cadddr f) (cadr f) args))))

(define (run e)
  (write e)
  (display " => ")
  (write (evaluate e primitives))
  (newline))

(run '(+ 1 (* 2 3)))
(run '(if (< 1 2) 10 20))
(run '(let ((x 5) (y 7)) (* x y)))
(run '((lambda (x) (* x x)) 9))
(run '(let ((make-adder (lambda (n) (lambda (x) (+ x n)))))
        ((make-adder 10) 5)))
;; 名前を持たない手続きで再帰するため、自分自身を引数に渡す。
(run '(let ((fact (lambda (self n)
                    (if (= n 0) 1 (* n (self self (- n 1)))))))
        (fact fact 10)))
