;;;; When this file's top level forms are run, it precomputes the
;;;; translations for built in classes. This stuff is split off from
;;;; the other type stuff to get around problems with everything
;;;; needing to be loaded before everything else. This file is the
;;;; first to exercise the type machinery.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-KERNEL")

;;; built-in classes
(/show0 "beginning class-init.lisp")
(dolist (x *builtin-classoids*)
  (destructuring-bind (name &key (translation nil trans-p) &allow-other-keys)
      x
    (/show "doing class with" name)
    (when trans-p
      (let ((classoid (classoid-cell-classoid (find-classoid-cell name :create t)))
            (type (specifier-type translation)))
        (when (typep (built-in-classoid-translation classoid) 'ctype)
          (aver (eq (built-in-classoid-translation classoid) type)))
        (setf (built-in-classoid-translation classoid) type)
        (setf (info :type :builtin name) type)))))

(/show0 "done with class-init.lisp")
