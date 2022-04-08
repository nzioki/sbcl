
;;; Please keep all the "smoke" tests in this file fairly lightweight.

;;; Don't crash on layoutless instances. It's that simple!
(defvar *l* nil)
(defun f (n) (dotimes (i n) (push (sb-kernel:%make-instance 5) *l*)))
(with-test (:name :layoutless-instance-no-crash)
  (f 20)
  (gc))

;;; Don't loop infinitely in mark_obj() on circular lists
(defvar *foo* (cons nil nil))
(rplacd *foo* *foo*)
(with-test (:name :circular-list) (gc :gen 7))
