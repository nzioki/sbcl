;;;; a bunch of handy macros for x86-64

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; instruction-like macros

;;; This used to be a macro (and still is on the other platforms) but
;;; the support for SC-dependent move instructions needed here makes
;;; that expand into so large an expression that the resulting code
;;; bloat is not justifiable.
(defun move (dst src &optional size)
  "Move SRC into DST unless they are location=."
  (unless (location= dst src)
    (sc-case dst
      ((single-reg complex-single-reg)
       (aver (xmm-tn-p src))
       (inst movaps dst src))
      ((double-reg complex-double-reg)
       (aver (xmm-tn-p src))
       (inst movapd dst src))
      #+sb-simd-pack
      ((int-sse-reg sse-reg)
       (aver (xmm-tn-p src))
       (inst movdqa dst src))
      #+sb-simd-pack
      ((single-sse-reg double-sse-reg)
       (aver (xmm-tn-p src))
       (inst movaps dst src))
      #+sb-simd-pack-256
      ((ymm-reg int-avx2-reg)
       (aver (xmm-tn-p src))
       (inst vmovdqa dst src))
      #+sb-simd-pack-256
      ((single-avx2-reg double-avx2-reg)
       (aver (xmm-tn-p src))
       (inst vmovaps dst src))
      (t
       (if size
           (inst mov size dst src)
           (inst mov dst src))))))

(defmacro object-slot-ea (ptr slot lowtag)
  `(ea (- (* ,slot n-word-bytes) ,lowtag) ,ptr))
(defmacro tls-index-of (sym)
  `(ea (+ 4 (- other-pointer-lowtag)) ,sym))

(defmacro loadw (value ptr &optional (slot 0) (lowtag 0))
  `(inst mov ,value (object-slot-ea ,ptr ,slot ,lowtag)))

(defun storew (value ptr &optional (slot 0) (lowtag 0))
  (let* ((size (if (tn-p value)
                   (sc-operand-size (tn-sc value))
                   :qword))
         (ea (ea (- (* slot n-word-bytes) lowtag) ptr)))
    (aver (eq size :qword))
    (cond ((and (integerp value)
                (not (typep value '(signed-byte 32))))
           (inst mov temp-reg-tn value)
           (inst mov ea temp-reg-tn))
          (t
           (inst mov :qword ea value)))))

(defmacro pushw (ptr &optional (slot 0) (lowtag 0))
  `(inst push (object-slot-ea ,ptr ,slot ,lowtag)))

(defmacro popw (ptr &optional (slot 0) (lowtag 0))
  `(inst pop (object-slot-ea ,ptr ,slot ,lowtag)))


;;;; macros to generate useful values

(defmacro load-symbol (reg symbol)
  `(inst mov ,reg (+ nil-value (static-symbol-offset ,symbol))))

;; Return the effective address of the value slot of static SYMBOL.
(defun static-symbol-value-ea (symbol &optional (byte 0))
   (ea (+ nil-value
          (static-symbol-offset symbol)
          (ash symbol-value-slot word-shift)
          byte
          (- other-pointer-lowtag))))

(defun thread-tls-ea (index)
  ;; Whether index is an an integer or a register, the EA constructor
  ;; call is the same.
  ;; Due to an encoding peculiarity, using thread-base-tn as the index register
  ;; is better when index is non-constant.
  ;; Base of r13 is reg=5 in ModRegRM, so if mod were 0, it would imply
  ;; RIP-relative addressing. (And attempting to encode an index is illegal)
  ;; So the 'mod' bits must be nonzero, which mandates encoding of an
  ;; explicit displacement of 0.  Using INDEX as base avoids the extra byte.
  (ea index thread-base-tn))

;;; assert that alloc-region->free_pointer and ->end_addr can be accessed
;;; using a single byte displacement from thread-base-tn
(eval-when (:compile-toplevel)
  (aver (<= (1+ thread-boxed-tlab-slot) 15))
  (aver (<= (1+ thread-unboxed-tlab-slot) 15)))

(defun thread-slot-ea (slot-index)
  (ea (ash slot-index word-shift) thread-base-tn))

#+sb-thread
(progn
  ;; Return an EA for the TLS of SYMBOL, or die.
  (defun symbol-known-tls-cell (symbol)
    (let ((index (info :variable :wired-tls symbol)))
      (aver (integerp index))
      (thread-tls-ea index)))

  ;; LOAD/STORE-TL-SYMBOL-VALUE macros are ad-hoc (ugly) emulations
  ;; of (INFO :VARIABLE :WIRED-TLS) = :ALWAYS-THREAD-LOCAL
  (defmacro load-tl-symbol-value (reg symbol)
    `(inst mov ,reg (symbol-known-tls-cell ',symbol)))

  (defmacro store-tl-symbol-value (reg symbol)
    `(inst mov (symbol-known-tls-cell ',symbol) ,reg)))

#-sb-thread
(progn
  (defmacro load-tl-symbol-value (reg symbol)
    `(inst mov ,reg (static-symbol-value-ea ',symbol)))
  (defmacro store-tl-symbol-value (reg symbol)
    `(inst mov (static-symbol-value-ea ',symbol) ,reg)))

(defmacro load-binding-stack-pointer (reg)
  `(load-tl-symbol-value ,reg *binding-stack-pointer*))

(defmacro store-binding-stack-pointer (reg)
  `(store-tl-symbol-value ,reg *binding-stack-pointer*))

;;;; error code
(defun emit-error-break (vop kind code values)
  (assemble ()
    (inst break)
    ;; The return PC points here; note the location for the debugger.
    (when vop
      (note-this-location vop :internal-error))
    (if (= kind invalid-arg-count-trap) ; there is no "payload" in this trap kind
        (inst byte kind)
        (emit-internal-error kind code values))))

(defun generate-error-code (vop error-code &rest values)
  (apply #'generate-error-code+ nil vop error-code values))

(defun generate-error-code+ (preamble-emitter vop error-code &rest values)
  "Generate-Error-Code Error-code Value*
  Emit code for an error with the specified Error-Code and context Values."
  (assemble (:elsewhere)
    (let ((start-lab (gen-label)))
      (emit-label start-lab)
      (when preamble-emitter
        (funcall preamble-emitter))
      (emit-error-break vop
                        (case error-code ; should be named ERROR-SYMBOL really
                          (invalid-arg-count-error invalid-arg-count-trap)
                          (t error-trap))
                        (error-number-or-lose error-code)
                        values)
      start-lab)))


;;;; PSEUDO-ATOMIC

;;; This is used to wrap operations which leave untagged memory lying
;;; around.  It's an operation which the AOP weenies would describe as
;;; having "cross-cutting concerns", meaning it appears all over the
;;; place and there's no logical single place to attach documentation.
;;; grep (mostly in src/runtime) is your friend

;;; Unsafely clear pa flags so that the image can properly lose in a
;;; pa section.
#+sb-thread
(defmacro %clear-pseudo-atomic ()
  '(inst mov :qword (thread-slot-ea thread-pseudo-atomic-bits-slot) 0))

#+sb-safepoint
(defun emit-safepoint ()
  ;; FIXME: need to get the node and policy to decide not to emit this safepoint.
  ;; Also, it would be good to emit only the last of consecutive safepoints in
  ;; straight-line code, e.g. (LIST (LIST X Y) (LIST Z W)) should emit 1 safepoint
  ;; not 3, even if we consider it 3 separate pointer bumps.
  ;; (Ideally we'd only do 1 pointer bump, but that's a separate issue)
  (inst test :byte rax-tn (ea (- static-space-start gc-safepoint-trap-offset))))

(defmacro pseudo-atomic ((&key elide-if) &rest forms)
  #+sb-safepoint
  `(progn ,@forms (unless ,elide-if (emit-safepoint)))
  #-sb-safepoint
  (with-unique-names (label pa-bits-ea)
    `(let ((,label (gen-label))
           (,pa-bits-ea
            #+sb-thread (thread-slot-ea thread-pseudo-atomic-bits-slot)
            #-sb-thread (static-symbol-value-ea '*pseudo-atomic-bits*)))
       (unless ,elide-if
         (inst mov ,pa-bits-ea rbp-tn))
       ,@forms
       (unless ,elide-if
         (inst xor ,pa-bits-ea rbp-tn)
         (inst jmp :z ,label)
         ;; if PAI was set, interrupts were disabled at the same time
         ;; using the process signal mask.
         (inst break pending-interrupt-trap)
         (emit-label ,label)))))

;;;; indexed references

(sb-xc:deftype load/store-index (scale lowtag min-offset
                                 &optional (max-offset min-offset))
  `(integer ,(- (truncate (+ (ash 1 16)
                             (* min-offset sb-vm:n-word-bytes)
                             (- lowtag))
                          scale))
            ,(truncate (- (+ (1- (ash 1 16)) lowtag)
                          (* max-offset sb-vm:n-word-bytes))
                       scale)))

(defmacro define-full-compare-and-swap
    (name type offset lowtag scs el-type &optional translate)
  `(progn
     (define-vop (,name)
         ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg) :to :eval)
              (index :scs (,@(when (member translate '(%instance-cas %raw-instance-cas/word))
                               '(immediate))
                           any-reg) :to :eval)
              (old-value :scs ,scs :target rax)
              (new-value :scs ,scs))
       (:arg-types ,type tagged-num ,el-type ,el-type)
       (:temporary (:sc descriptor-reg :offset rax-offset
                        :from (:argument 2) :to :result :target value)  rax)
       (:results (value :scs ,scs))
       (:result-types ,el-type)
       (:generator 5
         (move rax old-value)
         (inst cmpxchg :lock
               (ea (- (* (+ (if (sc-is index immediate) (tn-value index) 0) ,offset)
                         n-word-bytes)
                      ,lowtag)
                   object
                   (unless (sc-is index immediate) index)
                   (ash 1 (- word-shift n-fixnum-tag-bits)))
               new-value)
         (move value rax)))))

(defun bignum-index-check (bignum index addend vop)
  (declare (ignore bignum index addend vop))
  ;; Conditionally compile this in to sanity-check the bignum logic
  #+nil
  (let ((ok (gen-label)))
    (cond ((and (tn-p index) (not (constant-tn-p index)))
           (aver (sc-is index any-reg))
           (inst lea :dword temp-reg-tn (ea (fixnumize addend) index))
           (inst shr :dword temp-reg-tn n-fixnum-tag-bits))
          (t
           (inst mov temp-reg-tn (+ (if (tn-p index) (tn-value index) index) addend))))
    (inst cmp :dword temp-reg-tn (ea (- 1 other-pointer-lowtag) bignum))
    (inst jmp :b ok)
    (inst break halt-trap)
    (emit-label ok)))

(defmacro define-full-reffer (name type offset lowtag scs el-type &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate
           `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg)))
       (:arg-types ,type tagged-num)
       (:results (value :scs ,scs))
       (:result-types ,el-type)
       (:vop-var vop)
       (:generator 3                    ; pw was 5
         ,@(when (eq translate 'sb-bignum:%bignum-ref)
             '((bignum-index-check object index 0 vop)))
         (inst mov value (ea (- (* ,offset n-word-bytes) ,lowtag)
                             object index (ash 1 (- word-shift n-fixnum-tag-bits))))))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate
           `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)))
       (:info index)
       (:arg-types ,type
                   (:constant (load/store-index ,n-word-bytes ,(eval lowtag)
                                                ,(eval offset))))
       (:results (value :scs ,scs))
       (:result-types ,el-type)
       (:vop-var vop)
       (:generator 2                    ; pw was 5
         ,@(when (eq translate 'sb-bignum:%bignum-ref)
             '((bignum-index-check object index 0 vop)))
         (inst mov value (ea (- (* (+ ,offset index) n-word-bytes) ,lowtag)
                             object))))))

(defmacro define-full-reffer+addend (name type offset lowtag scs el-type &optional translate)
  (flet ((trap (index-to-encode)
           (declare (ignorable index-to-encode))
           #+ubsan
           ;; It's OK that the cell is read twice when testing for a trap value.
           ;; The value should only change from trapping to non-trapping, so if we loaded
           ;; a trap, and then one instruction later the data is valid (due to being
           ;; stored in another thread), then it's a false positive that is indicative
           ;; of a race. A false negative (failure to signal on a trap value) can not
           ;; occur unless unsafely using REPLACE into this vector.
           (when (memq name '(data-vector-ref-with-offset/simple-vector
                              data-vector-ref-with-offset/simple-vector-c))
             `((when (sb-c::policy (sb-c::vop-node vop) (> sb-c::aref-trapping 0))
                 (inst cmp :byte ea no-tls-value-marker-widetag)
                 (inst jmp :e (generate-error-code
                               vop 'uninitialized-element-error object
                               ,index-to-encode)))))))
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg)))
       (:info addend)
       (:arg-types ,type tagged-num
                   (:constant (constant-displacement other-pointer-lowtag
                                                     n-word-bytes vector-data-offset)))
       (:results (value :scs ,scs))
       (:result-types ,el-type)
       (:vop-var vop)
       (:generator 3
         ,@(when (eq translate 'sb-bignum:%bignum-ref-with-offset)
             '((bignum-index-check object index addend vop)))
         (let ((ea (ea (- (* (+ ,offset addend) n-word-bytes) ,lowtag)
                       object index (ash 1 (- word-shift n-fixnum-tag-bits)))))
           ,@(trap 'index)
           (inst mov value ea))))
     ;; This vop is really not ideal to have.  Couldn't we recombine two constants
     ;; and use a vop that only takes the object and just ONE index?
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)))
       (:info index addend)
       (:arg-types ,type
                   (:constant (load/store-index ,n-word-bytes ,(eval lowtag)
                                                ,(eval offset)))
                   (:constant (constant-displacement other-pointer-lowtag
                                                     n-word-bytes vector-data-offset)))
       (:results (value :scs ,scs))
       (:result-types ,el-type)
       (:vop-var vop)
       (:generator 2
         ,@(when (eq translate 'sb-bignum:%bignum-ref-with-offset)
             '((bignum-index-check object index addend vop)))
         (let ((ea (ea (- (* (+ ,offset index addend) n-word-bytes) ,lowtag) object)))
           ,@(trap '(emit-constant (+ index addend)))
           (inst mov value ea)))))))

;;; used for (SB-BIGNUM:%BIGNUM-SET %SET-FUNCALLABLE-INSTANCE-INFO
;;;           %SET-ARRAY-DIMENSION %SET-VECTOR-RAW-BITS)
(defmacro define-full-setter (name type offset lowtag scs el-type translate)
  `(define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg immediate))
              (value :scs ,scs))
       (:arg-types ,type tagged-num ,el-type)
       (:vop-var vop)
       (:generator 4
         ,@(when (eq translate 'sb-bignum:%bignum-set)
             '((bignum-index-check object index 0 vop)))
         (let ((ea (if (sc-is index immediate)
                       (ea (- (* (+ ,offset (tn-value index)) n-word-bytes) ,lowtag)
                           object)
                       (ea (- (* ,offset n-word-bytes) ,lowtag)
                           object index (ash 1 (- word-shift n-fixnum-tag-bits))))))
           ,(if (eq name 'set-funcallable-instance-info)
                '(pseudo-atomic () ; if immobile space, need to touch a card mark bit
                  (inst push object)
                  (invoke-asm-routine 'call 'touch-gc-card vop)
                  (gen-cell-set ea value))
                '(gen-cell-set ea value))))))
