
(defparameter foofafoof (vector 0 0 0 0))
(defglobal random-index nil)
(defun try-ccase (x)
  ;; We evaluate subforms of the keyform in CCASE (and CTYPECASE) once only.
  ;; This is *not* a spec requirement because
  ;;  "The subforms of keyplace might be evaluated again if none of the cases holds."
  ;; but it is an aspect of this particular implementation.
  (ccase (aref foofafoof (let ((r (random x)))
                           (assert (not random-index))
                           (setq random-index r)
                           r))
    ((a b) 'a-or-b)
    (c 'see)))

(with-test (:name :ccase-subforms-once-only)
  ;; There should be exactly one use each of UNBOUND-SYMBOL and OBJECT-NOT-VECTOR.
  (let ((ct-err-not-vector 0)
        (ct-err-not-boundp 0))
    (dolist (line (split-string
                   (with-output-to-string (stream)
                     (disassemble 'try-ccase :stream stream))
                   #\newline))
      (cond ((search "OBJECT-NOT-VECTOR" line) (incf ct-err-not-vector))
            ((search "UNBOUND-SYMBOL-ERROR" line) (incf ct-err-not-boundp))))
    (assert (and (= ct-err-not-vector 1)
                 (= ct-err-not-boundp 1))))
  (handler-bind ((type-error (lambda (condition)
                               (declare (ignorable condition))
                               (invoke-restart 'store-value 'b))))
    (try-ccase 4))
  (assert (eq (aref foofafoof random-index) 'b)))
