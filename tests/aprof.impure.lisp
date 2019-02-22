;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;;
;;;; This software is in the public domain and is provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for
;;;; more information.

#-(and x86-64 sb-thread) (sb-ext:exit :code 104) ;; not implemented elsewhere

(with-test (:name :aprof-smoketest-struct
            ;; reverse-engineering the allocation instructions fails but should not
            :fails-on (or (not :immobile-space) :sb-safepoint))
  (let ((nbytes
         (sb-aprof:aprof-run
            (checked-compile
             '(sb-int:named-lambda "test" ()
                (declare (inline sb-thread:make-mutex)
                         (optimize sb-c::instrument-consing))
                (loop repeat 50 collect (sb-thread:make-mutex))))
            :stream nil)))
    (assert (= nbytes
                (+ (* 51 2 sb-vm:n-word-bytes) ; list (extra for dummy head)
                   (* 50 (sb-vm::primitive-object-size
                          (sb-thread:make-mutex))))))))

(with-test (:name :aprof-smoketest-non-constant-size-vector
            :broken-on :win32)
  (let ((nbytes
         (sb-aprof:aprof-run
            (checked-compile
             '(sb-int:named-lambda "test" (&optional (n 10))
                (declare (optimize sb-c::instrument-consing))
                (make-array (the (mod 64) n))))
            :stream nil)))
    (assert (= nbytes (* 12 sb-vm:n-word-bytes)))))

;;; The profiler's disassembler expected to see a store at alloc-ptr
;;; or that + n-word-bytes, when in fact the code might write to 1 byte
;;; positioned anywhere in the word after the object header.
(with-test (:name :aprof-smoketest-bit-vector
            :fails-on :win32)
  (let ((nbytes
         (sb-aprof:aprof-run
            (checked-compile
             '(sb-int:named-lambda "test" ()
                (declare (optimize sb-c::instrument-consing))
                (make-array (* 128 16) :element-type 'bit)))
            :stream nil)))
    (assert (= nbytes (sb-vm::primitive-object-size
                       (make-array (* 128 16) :element-type 'bit))))))

(with-test (:name :aprof-smoketest-large-vector
            :fails-on :win32)
  (let ((nbytes
         (sb-aprof:aprof-run
             (checked-compile
              '(sb-int:named-lambda "test" ()
                (declare (optimize sb-c::instrument-consing))
                (make-array 45000)))
             :stream nil)))
    (assert (= nbytes (* (+ 45000 sb-vm:vector-data-offset)
                         8)))))
sb-vm::
(define-vop (cl-user::alloc-to-r8)
  (:temporary (:sc any-reg :offset r8-offset :from :eval) result)
  (:node-var node)
  (:generator 1
    (let* ((bytes large-object-size) ; payload + header total
           (words (- (/ bytes n-word-bytes) vector-data-offset)))
      (instrument-alloc bytes node)
      (pseudo-atomic ()
       (allocation result bytes node nil other-pointer-lowtag)
       (storew* simple-array-unsigned-byte-64-widetag result 0
                other-pointer-lowtag t)
       (storew* (fixnumize words) result vector-length-slot
                other-pointer-lowtag t)))))

(with-test (:name :aprof-smoketest-large-vector-to-upper-register
            :fails-on :win32)
  (let ((nbytes
         (sb-aprof:aprof-run
             (checked-compile
              '(sb-int:named-lambda "test" ()
                (declare (optimize sb-c::instrument-consing))
                (sb-sys:%primitive cl-user::alloc-to-r8)
                nil))
             :stream nil)))
    (assert (= nbytes sb-vm:large-object-size))))

;; this moves an immediate-to-memory, then a load + store, then a store
(defun f1 (&optional x)
  (declare (optimize sb-c::instrument-consing))
  (list* :if-exists (load-time-value(gensym)) x))
;; this reverses the first two operations relative to the preceding
(defun f2 (&optional x)
  (declare (optimize sb-c::instrument-consing))
  (list* (load-time-value(gensym)) :if-exists x))

#-win32
(with-test (:name :aprof-list-length-2)
  ;; Rather than figuring out how to get some minimal piece of Lisp code to
  ;; compile into exactly these instruction encodings below which caused aprof
  ;; to fail, just check the assembled code directly.
  (let ((bytes
         (coerce
          `(#xF0 #x49 #xFF #x83 #x80 #x64 #x00 #x00
            #x49 #x89 #x6D ,(* sb-vm::thread-pseudo-atomic-bits-slot 8)
            #x4D #x8B #x55 #x20
            #x4D #x8D #x5A #x20
            #x4D #x3B #x5D #x28
            #x0F #x87 #x9E #x02 #x00 #x00
            #x4D #x89 #x5D #x20
            #x4C #x8B #x4D #xC8
            #x4D #x89 #x0A
            #x4D #x8D #x4A #x17
            #x4D #x89 #x4A #x08
            #x49 #x89 #x72 #x10
            #x41 #xC7 #x42 #x18 #x17 #x00 #x10 #x50
            #x41 #x80 #xCA #x07)
          '(simple-array (unsigned-byte 8) (*)))))
    (sb-sys:with-pinned-objects (bytes)
      (multiple-value-bind (type size)
          (sb-aprof::infer-type (sb-sys:sap-int (sb-sys:vector-sap bytes)) bytes)
        (assert (eq type 'list))
        (assert (= size (* 2 sb-vm:cons-size sb-vm:n-word-bytes))))))
  (compile 'f1)
  (compile 'f2)
  (assert (= (sb-aprof:aprof-run #'f1 :stream nil) 32))
  (assert (= (sb-aprof:aprof-run #'f2 :stream nil) 32)))
