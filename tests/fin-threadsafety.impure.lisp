#-sb-thread (sb-ext:exit :code 104)

(use-package "SB-THREAD")

(let ((count (make-array 8 :initial-element 0)))
  (defun closure-one ()
    (declare (optimize safety))
    (values (incf (aref count 0)) (incf (aref count 1))
            (incf (aref count 2)) (incf (aref count 3))
            (incf (aref count 4)) (incf (aref count 5))
            (incf (aref count 6)) (incf (aref count 7))))
  (defun no-optimizing-away-closure-one ()
    (setf count (make-array 8 :initial-element 0))))

(defstruct box
  (count 0))

(let ((one (make-box))
      (two (make-box))
      (three (make-box)))
  (defun closure-two ()
    (declare (optimize safety))
    (values (incf (box-count one)) (incf (box-count two)) (incf (box-count three))))
  (defun no-optimizing-away-closure-two ()
    (setf one (make-box)
          two (make-box)
          three (make-box))))

;;; PowerPC safepoint builds occasionally hang or busy-loop (or
;;; sometimes run out of memory) in the following test.  For developers
;;; interested in debugging this combination of features, it might be
;;; fruitful to concentrate their efforts around this test...

(with-test (:name (:funcallable-instances)
            :broken-on (and :sb-safepoint (not :c-stack-is-control-stack)))
  ;; the funcallable-instance implementation used not to be threadsafe
  ;; against setting the funcallable-instance function to a closure
  ;; (because the code and lexenv were set separately).
  (let ((fun (sb-kernel:%make-funcallable-instance 0))
        (stop nil)
        (condition nil))
    (setf (sb-kernel:%funcallable-instance-fun fun) #'closure-one)
    (flet ((changer ()
             (loop (sb-thread:barrier (:read))
                   (when stop (return))
                   (setf (sb-kernel:%funcallable-instance-fun fun) #'closure-one)
                   (setf (sb-kernel:%funcallable-instance-fun fun) #'closure-two)))
           (test ()
             (handler-case (loop (sb-thread:barrier (:read))
                                 (when stop (return))
                                 (funcall fun))
               (serious-condition (c) (setf condition c)))))
      (let ((changer (make-thread #'changer :name "changer"))
            (test (make-thread #'test :name "test")))
              ;; The two closures above are fairly carefully crafted
              ;; so that if given the wrong lexenv they will tend to
              ;; do some serious damage, but it is of course difficult
              ;; to predict where the various bits and pieces will be
              ;; allocated.  Five seconds failed fairly reliably on
              ;; both my x86 and x86-64 systems.  -- CSR, 2006-09-27.
        (sleep 5)
        (setq stop t)
        (sb-thread:barrier (:write))
        (wait-for-threads (list changer test))))))
