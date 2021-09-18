;;;; the VM definition of various primitive memory access VOPs for the
;;;; PPC

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Data object ref/set stuff.

;;; PPC64 can't use the NIL-as-CONS + NIL-as-symbol trick *and* avoid using
;;; temp-reg-tn to access symbol slots.
;;; Since the NIL-as-CONS is necessary, and efficient accessor to lists and
;;; instances is desirable, we lose a little on symbol access by being forced
;;; to pre-check for NIL. There is trick that can get back some performance
;;; on SYMBOL-VALUE which I plan to implement after this much works right.
(define-vop (slot)
  (:args (object :scs (descriptor-reg)))
  (:info name offset lowtag)
  (:results (result :scs (descriptor-reg any-reg)))
  (:generator 1
    (cond ((member name '(symbol-name symbol-info sb-xc:symbol-package))
           (let ((null-label (gen-label))
                 (done-label (gen-label)))
             (inst cmpld object null-tn)
             (inst beq null-label)
             (loadw result object offset lowtag)
             (inst b done-label)
             (emit-label null-label)
             (loadw result object (1- offset) list-pointer-lowtag)
             (emit-label done-label)))
          (t
           (loadw result object offset lowtag)))))

(define-vop (set-slot)
  (:args (object :scs (descriptor-reg))
         (value :scs (descriptor-reg any-reg)))
  (:info name offset lowtag)
  (:ignore name)
  (:results)
  (:generator 1
    (storew value object offset lowtag)))

(define-vop (compare-and-swap-slot)
  (:args (object :scs (descriptor-reg))
         (old :scs (descriptor-reg any-reg))
         (new :scs (descriptor-reg any-reg)))
  (:temporary (:sc non-descriptor-reg) temp)
  (:info name offset lowtag)
  (:ignore name)
  (:results (result :scs (descriptor-reg) :from :load))
  (:generator 5
    (inst sync)
    (inst li temp (- (* offset n-word-bytes) lowtag))
    LOOP
    (inst ldarx result temp object)
    (inst cmpd result old)
    (inst bne EXIT)
    (inst stdcx. new temp object)
    (inst bne LOOP)
    EXIT
    (inst isync)))


;;;; Symbol hacking VOPs:

(define-vop (%compare-and-swap-symbol-value)
  (:translate %compare-and-swap-symbol-value)
  (:args (symbol :scs (descriptor-reg))
         (old :scs (descriptor-reg any-reg))
         (new :scs (descriptor-reg any-reg)))
  (:temporary (:sc non-descriptor-reg) temp)
  (:results (result :scs (descriptor-reg any-reg) :from :load))
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 15
    (inst sync)
    #+sb-thread
    (assemble ()
      (load-tls-index temp symbol)
      ;; Thread-local area, no synchronization needed.
      (inst ldx result thread-base-tn temp)
      (inst cmpd result old)
      (inst bne DONT-STORE-TLS)
      (inst stdx new thread-base-tn temp)
      DONT-STORE-TLS

      (inst cmpdi result no-tls-value-marker-widetag)
      (inst bne CHECK-UNBOUND))

    (inst li temp (- (* symbol-value-slot n-word-bytes)
                     other-pointer-lowtag))
    LOOP
    (inst ldarx result symbol temp)
    (inst cmpd result old)
    (inst bne CHECK-UNBOUND)
    (inst stdcx. new symbol temp)
    (inst bne LOOP)

    CHECK-UNBOUND
    (inst isync)
    (inst cmpdi result unbound-marker-widetag)
    (inst beq (generate-error-code vop 'unbound-symbol-error symbol))))

;;; The compiler likes to be able to directly SET symbols.
(define-vop (%set-symbol-global-value cell-set)
  (:variant symbol-value-slot other-pointer-lowtag))

;;; Do a cell ref with an error check for being unbound.
(define-vop (checked-cell-ref)
  (:args (object :scs (descriptor-reg) :target obj-temp))
  (:results (value :scs (descriptor-reg any-reg)))
  (:policy :fast-safe)
  (:vop-var vop)
  (:save-p :compute-only)
  (:temporary (:scs (descriptor-reg) :from (:argument 0)) obj-temp))

;;; With SYMBOL-VALUE, we check that the value isn't the trap object.
;;; So SYMBOL-VALUE of NIL is NIL.
(define-vop (symbol-global-value checked-cell-ref)
  (:translate sym-global-val)
  (:generator 9
    ;; TODO: can this be made branchless somehow?
    (inst cmpld object null-tn)
    (inst beq NULL)
    (move obj-temp object)
    (loadw value obj-temp symbol-value-slot other-pointer-lowtag)
    (let ((err-lab (generate-error-code vop 'unbound-symbol-error obj-temp)))
      (inst cmpwi value unbound-marker-widetag)
      (inst beq err-lab))
    (inst b DONE)
    NULL
    (move value object)
    DONE))

(define-vop (fast-symbol-global-value cell-ref)
  (:variant symbol-value-slot other-pointer-lowtag)
  (:policy :fast)
  (:translate sym-global-val)
  (:ignore offset lowtag)
  (:generator 7
    (inst cmpld object null-tn)
    (inst beq NULL)
    (loadw value object symbol-value-slot other-pointer-lowtag)
    (inst b DONE)
    NULL
    (move value object)
    DONE))

#+sb-thread
(progn
  (define-vop (set)
    (:args (symbol :scs (descriptor-reg))
           (value :scs (descriptor-reg any-reg)))
    (:temporary (:sc any-reg) tls-slot temp)
    (:generator 4
      (load-tls-index tls-slot symbol)
      (inst ldx temp thread-base-tn tls-slot)
      (inst cmpdi temp no-tls-value-marker-widetag)
      (inst beq GLOBAL-VALUE)
      (inst stdx value thread-base-tn tls-slot)
      (inst b DONE)
      GLOBAL-VALUE
      (storew value symbol symbol-value-slot other-pointer-lowtag)
      DONE))

  ;; With Symbol-Value, we check that the value isn't the trap object. So
  ;; Symbol-Value of NIL is NIL.
  (define-vop (symbol-value)
    (:translate symeval)
    (:policy :fast-safe)
    (:args (object :scs (descriptor-reg) :to (:result 1)))
    (:results (value :scs (descriptor-reg any-reg)))
    (:vop-var vop)
    (:save-p :compute-only)
    (:generator 9
      (inst cmpld object null-tn)
      (inst beq NULL)
      (load-tls-index value object)
      (inst ldx value thread-base-tn value)
      (inst cmpdi value no-tls-value-marker-widetag)
      (inst bne CHECK-UNBOUND)
      (loadw value object symbol-value-slot other-pointer-lowtag)
      CHECK-UNBOUND
      (inst cmpdi value unbound-marker-widetag)
      (inst beq (generate-error-code vop 'unbound-symbol-error object))
      (inst b DONE)
      NULL
      (move value object)
      DONE))

  (define-vop (fast-symbol-value symbol-value)
    ;; KLUDGE: not really fast, in fact, because we're going to have to
    ;; do a full lookup of the thread-local area anyway.  But half of
    ;; the meaning of FAST-SYMBOL-VALUE is "do not signal an error if
    ;; unbound", which is used in the implementation of COPY-SYMBOL.  --
    ;; CSR, 2003-04-22
    (:policy :fast)
    (:translate symeval)
    (:generator 8
      (inst cmpld object null-tn)
      (inst beq NULL)
      (load-tls-index value object)
      (inst ldx value thread-base-tn value)
      (inst cmpdi value no-tls-value-marker-widetag)
      (inst bne DONE)
      (loadw value object symbol-value-slot other-pointer-lowtag)
      (inst b DONE)
      NULL
      (move value object)
      DONE)))

;;; On unithreaded builds these are just copies of the global versions.
#-sb-thread
(progn
  (define-vop (symbol-value symbol-global-value)
    (:translate symeval))
  (define-vop (fast-symbol-value fast-symbol-global-value)
    (:translate symeval))
  (define-vop (set %set-symbol-global-value)))

;;; Like CHECKED-CELL-REF, only we are a predicate to see if the cell
;;; is bound.
(define-vop (boundp-frob)
  (:args (object :scs (descriptor-reg)))
  (:conditional)
  (:info target not-p)
  (:policy :fast-safe)
  (:temporary (:scs (descriptor-reg)) value))

#+sb-thread
(define-vop (boundp boundp-frob)
  (:translate boundp)
  (:generator 9
    (inst cmpld object null-tn)
    (inst beq (if not-p out target))
    (load-tls-index value object)
    (inst ldx value thread-base-tn value)
    (inst cmpdi value no-tls-value-marker-widetag)
    (inst bne CHECK-UNBOUND)
    (loadw value object symbol-value-slot other-pointer-lowtag)
    CHECK-UNBOUND
    (inst cmpdi value unbound-marker-widetag)
    (inst b? (if not-p :eq :ne) target)
    OUT))

#-sb-thread
(define-vop (boundp boundp-frob)
  (:translate boundp)
  (:generator 9
    (loadw value object symbol-value-slot other-pointer-lowtag)
    (inst cmpwi value unbound-marker-widetag)
    (inst b? (if not-p :eq :ne) target)))

(define-vop (symbol-hash)
  (:policy :fast-safe)
  (:translate symbol-hash)
  (:args (symbol :scs (descriptor-reg)))
  (:results (res :scs (any-reg)))
  (:result-types positive-fixnum)
  (:args-var args)
  (:generator 4
    (when (not-nil-tn-ref-p args)
      (loadw res symbol symbol-hash-slot other-pointer-lowtag)
      (return-from symbol-hash))
    (inst cmpld symbol null-tn)
    (inst beq NULL)
    (loadw res symbol symbol-hash-slot other-pointer-lowtag)
    (inst b DONE)
    NULL
    (inst addi res null-tn (- (logand sb-vm:nil-value sb-vm:fixnum-tag-mask)))
    DONE))
(define-vop (symbol-plist)
  (:policy :fast-safe)
  (:translate symbol-plist)
  (:args (symbol :scs (descriptor-reg)))
  (:results (res :scs (descriptor-reg)))
  (:temporary (:scs (unsigned-reg)) temp)
  (:generator 6
    (inst cmpld symbol null-tn)
    (inst beq NULL)
    (loadw res symbol symbol-info-slot other-pointer-lowtag)
    (inst andi. temp res lowtag-mask)
    (inst cmpwi temp list-pointer-lowtag)
    (inst beq take-car)
    (move res null-tn) ; if INFO is a non-list, then the PLIST is NIL
    (inst b DONE)
    NULL
    (loadw res symbol (1- symbol-info-slot) list-pointer-lowtag)
    ;; fallthru. NULL's info slot always holds a cons
    TAKE-CAR
    (loadw res res cons-car-slot list-pointer-lowtag)
    DONE))

;;;; Fdefinition (fdefn) objects.

(define-vop (fdefn-fun cell-ref) ; does not translate anything
  (:variant fdefn-fun-slot other-pointer-lowtag))
(define-vop (untagged-fdefn-fun cell-ref) ; does not translate anything
  (:variant fdefn-fun-slot 0))

(define-vop (safe-fdefn-fun)
  (:translate safe-fdefn-fun)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg) :target obj-temp))
  (:results (value :scs (descriptor-reg any-reg)))
  (:vop-var vop)
  (:save-p :compute-only)
  (:temporary (:scs (descriptor-reg) :from (:argument 0)) obj-temp)
  (:generator 10
    (move obj-temp object)
    (loadw value obj-temp fdefn-fun-slot other-pointer-lowtag)
    (inst cmpd value null-tn)
    (let ((err-lab (generate-error-code vop 'undefined-fun-error obj-temp)))
      (inst beq err-lab))))
;;; We need the ordinary safe-fdefn-fun *and* the untagged one. The tagged vop
;;; translates calls which store and pass fdefns as objects:
;;;  - a readtable can map a character to an fdefn (or a function)
;;;  - handler clusters can bind a condition to an fdefn (or function)
;;;  - maybe more
;;; Those uses want the lazy lookup aspect while being faster than symbol-function.
;;; References within code never manipulate the fdefn as an object.
;;; Luckily there is no ambiguity in the undefined-fun trap when it receives
;;; an integer in a descriptor register: it's a "stealth mode" fdefn.
(define-vop (safe-untagged-fdefn-fun) ; does not translate anything
  (:policy :fast-safe)
  ;; I've given up on the idea that untagged fdefns shall only be loaded into fdefn-tn.
  ;; Because of error handling, the GC has to allow them to be seen anywhere,
  ;; conservatively not touching the bits.
  (:args (object :scs (descriptor-reg) :target obj-temp))
  (:results (value :scs (descriptor-reg any-reg)))
  (:vop-var vop)
  (:save-p :compute-only)
  (:temporary (:scs (descriptor-reg) :from (:argument 0)) obj-temp)
  (:generator 10
    (move obj-temp object)
    (loadw value obj-temp fdefn-fun-slot 0)
    (inst cmpd value null-tn)
    (let ((err-lab (generate-error-code vop 'undefined-fun-error obj-temp)))
      (inst beq err-lab))))

(define-vop (set-fdefn-fun)
  (:policy :fast-safe)
  (:translate (setf fdefn-fun))
  (:args (function :scs (descriptor-reg) :target result)
         (fdefn :scs (descriptor-reg)))
  (:temporary (:scs (interior-reg)) lip)
  (:temporary (:scs (non-descriptor-reg)) type)
  (:results (result :scs (descriptor-reg)))
  (:generator 38
    (let ((normal-fn (gen-label)))
      (load-type type function (- fun-pointer-lowtag))
      (inst cmpdi type simple-fun-widetag)
      ;;(inst mr lip function)
      (inst addi lip function
            (- (ash simple-fun-insts-offset word-shift) fun-pointer-lowtag))
      (inst beq normal-fn)
      (inst addi lip null-tn (make-fixup 'closure-tramp :asm-routine-nil-offset))
      (emit-label normal-fn)
      (storew lip fdefn fdefn-raw-addr-slot other-pointer-lowtag)
      (storew function fdefn fdefn-fun-slot other-pointer-lowtag)
      (move result function))))

(define-vop (fdefn-makunbound)
  (:policy :fast-safe)
  (:translate fdefn-makunbound)
  (:args (fdefn :scs (descriptor-reg) :target result))
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:results (result :scs (descriptor-reg)))
  (:generator 38
    (storew null-tn fdefn fdefn-fun-slot other-pointer-lowtag)
    (inst addi temp null-tn (make-fixup 'undefined-tramp :asm-routine-nil-offset))
    (storew temp fdefn fdefn-raw-addr-slot other-pointer-lowtag)
    (move result fdefn)))



;;;; Binding and Unbinding.

;;; BIND -- Establish VAL as a binding for SYMBOL.  Save the old value and
;;; the symbol on the binding stack and stuff the new value into the
;;; symbol.
;;; See the "Chapter 9: Specials" of the SBCL Internals Manual.
#+sb-thread
(define-vop (dynbind)
  (:args (val :scs (any-reg descriptor-reg))
         (symbol :scs (descriptor-reg)))
  (:temporary (:scs (descriptor-reg)) temp)
  (:generator 5
    (let ((tls-index temp-reg-tn))
     (load-tls-index tls-index symbol)
     (inst twi :eq tls-index 0)
     (inst ldx temp thread-base-tn tls-index)
     (inst addi bsp-tn bsp-tn (* binding-size n-word-bytes))
     (storew temp bsp-tn (- binding-value-slot binding-size))
     (storew tls-index bsp-tn (- binding-symbol-slot binding-size))
     (inst stdx val thread-base-tn tls-index))))

#-sb-thread
(define-vop (dynbind)
  (:args (val :scs (any-reg descriptor-reg))
         (symbol :scs (descriptor-reg)))
  (:temporary (:scs (descriptor-reg)) temp)
  (:generator 5
    (loadw temp symbol symbol-value-slot other-pointer-lowtag)
    (inst addi bsp-tn bsp-tn (* binding-size n-word-bytes))
    (storew temp bsp-tn (- binding-value-slot binding-size))
    (storew symbol bsp-tn (- binding-symbol-slot binding-size))
    (storew val symbol symbol-value-slot other-pointer-lowtag)))

#+sb-thread
(define-vop (unbind)
  (:temporary (:scs (descriptor-reg)) tls-index value)
  (:temporary (:scs (any-reg)) zero)
  (:generator 0
    (loadw tls-index bsp-tn (- binding-symbol-slot binding-size))
    (loadw value bsp-tn (- binding-value-slot binding-size))
    (inst stdx value thread-base-tn tls-index)
    (inst li zero 0)
    (storew zero bsp-tn (- binding-symbol-slot binding-size))
    (storew zero bsp-tn (- binding-value-slot binding-size))
    (inst subi bsp-tn bsp-tn (* binding-size n-word-bytes))))

#-sb-thread
(define-vop (unbind)
  (:temporary (:scs (descriptor-reg)) symbol value)
  (:temporary (:scs (any-reg)) zero)
  (:generator 0
    (loadw symbol bsp-tn (- binding-symbol-slot binding-size))
    (loadw value bsp-tn (- binding-value-slot binding-size))
    (storew value symbol symbol-value-slot other-pointer-lowtag)
    (inst li zero 0)
    (storew zero bsp-tn (- binding-symbol-slot binding-size))
    (storew zero bsp-tn (- binding-value-slot binding-size))
    (inst subi bsp-tn bsp-tn (* binding-size n-word-bytes))))


(define-vop (unbind-to-here)
  (:args (arg :scs (descriptor-reg any-reg) :target where))
  (:temporary (:scs (any-reg) :from (:argument 0)) where zero)
  (:temporary (:scs (descriptor-reg)) symbol value)
  (:generator 0
      (move where arg)
      (inst cmpd where bsp-tn)
      (inst beq done)
      (inst li zero 0)

      LOOP
      (loadw symbol bsp-tn (- binding-symbol-slot binding-size))
      (inst cmpdi symbol 0)
      (inst beq skip)
      (loadw value bsp-tn (- binding-value-slot binding-size))
      #+sb-thread
      (inst stdx value thread-base-tn symbol)
      #-sb-thread
      (storew value symbol symbol-value-slot other-pointer-lowtag)
      (storew zero bsp-tn (- binding-symbol-slot binding-size))

      SKIP
      (storew zero bsp-tn (- binding-value-slot binding-size))
      (inst subi bsp-tn bsp-tn (* binding-size n-word-bytes))
      (inst cmpd where bsp-tn)
      (inst bne loop)

      DONE))



;;;; Closure indexing.

(define-vop (closure-index-ref word-index-ref)
  (:variant closure-info-offset fun-pointer-lowtag)
  (:translate %closure-index-ref))

(define-vop (funcallable-instance-info word-index-ref)
  (:variant funcallable-instance-info-offset fun-pointer-lowtag)
  (:translate %funcallable-instance-info))

(define-vop (set-funcallable-instance-info word-index-set-nr)
  (:variant funcallable-instance-info-offset fun-pointer-lowtag)
  (:translate %set-funcallable-instance-info))

(define-vop (closure-ref)
  (:args (object :scs (descriptor-reg)))
  (:results (value :scs (descriptor-reg any-reg)))
  (:info offset)
  (:generator 4
    (loadw value object (+ closure-info-offset offset) fun-pointer-lowtag)))

(define-vop (closure-init)
  (:args (object :scs (descriptor-reg))
         (value :scs (descriptor-reg any-reg)))
  (:info offset)
  (:generator 4
    (storew value object (+ closure-info-offset offset) fun-pointer-lowtag)))

(define-vop (closure-init-from-fp)
  (:args (object :scs (descriptor-reg)))
  (:info offset)
  (:generator 4
    (storew cfp-tn object (+ closure-info-offset offset) fun-pointer-lowtag)))

;;;; Value Cell hackery.

(define-vop (value-cell-ref cell-ref)
  (:variant value-cell-value-slot other-pointer-lowtag))

(define-vop (value-cell-set cell-set)
  (:variant value-cell-value-slot other-pointer-lowtag))



;;;; Instance hackery:

(define-vop ()
  (:policy :fast-safe)
  (:translate %instance-length)
  (:args (struct :scs (descriptor-reg)))
  (:results (res :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 4
    (loadw res struct 0 instance-pointer-lowtag)
    (inst srwi res res instance-length-shift)))

(define-vop (instance-index-ref word-index-ref)
  (:policy :fast-safe)
  (:translate %instance-ref)
  (:variant instance-slots-offset instance-pointer-lowtag)
  (:arg-types instance positive-fixnum))

(define-vop (instance-index-set word-index-set)
  (:policy :fast-safe)
  (:translate %instance-set)
  (:variant instance-slots-offset instance-pointer-lowtag)
  (:arg-types instance positive-fixnum *))

(define-vop (%instance-cas word-index-cas)
  (:policy :fast-safe)
  (:translate %instance-cas)
  (:variant instance-slots-offset instance-pointer-lowtag)
  (:arg-types instance tagged-num * *))
(define-vop (%raw-instance-cas/word %instance-cas)
  (:args (object)
         (index)
         (old-value :scs (unsigned-reg))
         (new-value :scs (unsigned-reg)))
  (:arg-types * tagged-num unsigned-num unsigned-num)
  (:results (result :scs (unsigned-reg) :from :load))
  (:result-types unsigned-num)
  (:translate %raw-instance-cas/word))


;;;; Code object frobbing.

(define-vop (code-header-ref-any)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg)))
  (:arg-types * tagged-num)
  (:results (value :scs (descriptor-reg)))
  (:policy :fast-safe)
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:generator 2
    ;; ASSUMPTION: N-FIXNUM-TAG-BITS = 3
    (inst addi temp index (- other-pointer-lowtag))
    (inst ldx value object temp)))

(define-vop (code-header-ref-fdefn)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg)))
  (:arg-types * tagged-num)
  (:results (value :scs (descriptor-reg)))
  (:policy :fast-safe)
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:generator 3
    ;; ASSUMPTION: N-FIXNUM-TAG-BITS = 3
    (inst addi temp index (- other-pointer-lowtag))
    ;; Loaded value is automatically pinned.
    (inst ldx value object temp)
    (inst ori value value other-pointer-lowtag)))

#-sb-xc-host
(defun code-header-ref (code index)
  (declare (index index))
  (let ((fdefns-start (sb-impl::code-fdefns-start-index code))
        (count (code-n-named-calls code)))
    (declare ((unsigned-byte 16) fdefns-start count))
    (if (and (>= index fdefns-start) (< index (+ fdefns-start count)))
        (%primitive code-header-ref-fdefn code index)
        (%primitive code-header-ref-any code index))))

(define-vop (code-header-set word-index-set-nr)
  (:translate code-header-set)
  (:policy :fast-safe)
  (:variant 0 other-pointer-lowtag))



;;;; raw instance slot accessors

(defun offset-for-raw-slot (index &optional (displacement 0))
  (- (+ (ash (+ index instance-slots-offset) word-shift)
        displacement)
     instance-pointer-lowtag))

(macrolet ((def (suffix sc primtype)
             `(progn
                (define-vop (,(symbolicate "%RAW-INSTANCE-REF/" suffix) word-index-ref)
                  (:policy :fast-safe)
                  (:translate ,(symbolicate "%RAW-INSTANCE-REF/" suffix))
                  (:variant instance-slots-offset instance-pointer-lowtag)
                  (:arg-types instance positive-fixnum)
                  (:results (value :scs (,sc)))
                  (:result-types ,primtype))
                (define-vop (,(symbolicate "%RAW-INSTANCE-SET/" suffix) word-index-set-nr)
                  (:policy :fast-safe)
                  (:translate ,(symbolicate "%RAW-INSTANCE-SET/" suffix))
                  (:variant instance-slots-offset instance-pointer-lowtag)
                  (:arg-types instance positive-fixnum ,primtype)
                  (:args (object) (index) (value :scs (,sc)))))))
  (def word unsigned-reg unsigned-num)
  (def signed-word signed-reg signed-num))

(define-vop (raw-instance-atomic-incf/word)
  (:translate %raw-instance-atomic-incf/word)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg)) ; FIXME: allow immediate
         (diff :scs (unsigned-reg)))
  (:arg-types * positive-fixnum unsigned-num)
  (:temporary (:sc unsigned-reg) offset)
  (:temporary (:sc non-descriptor-reg) sum)
  (:results (result :scs (unsigned-reg) :from :load))
  (:result-types unsigned-num)
  (:generator 4
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                                instance-pointer-lowtag))
    ;; load the slot value, add DIFF, write the sum back, and return
    ;; the original slot value, atomically, and include a memory
    ;; barrier.
    (inst sync)
    LOOP
    (inst ldarx result offset object)
    (inst add sum result diff)
    (inst stdcx. sum offset object)
    (inst bne LOOP)
    (inst isync)))

(define-vop ()
  (:translate %raw-instance-ref/single)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg)))
  (:arg-types * positive-fixnum)
  (:results (value :scs (single-reg)))
  (:temporary (:scs (non-descriptor-reg)) offset)
  (:result-types single-float)
  (:generator 5
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                               instance-pointer-lowtag))
    (inst lfsx value object offset)))

(define-vop ()
  (:translate %raw-instance-set/single)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg))
         (value :scs (single-reg)))
  (:arg-types * positive-fixnum single-float)
  (:temporary (:scs (non-descriptor-reg)) offset)
  (:generator 5
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                               instance-pointer-lowtag))
    (inst stfsx value object offset)))

(define-vop ()
  (:translate %raw-instance-ref/double)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg)))
  (:arg-types * positive-fixnum)
  (:results (value :scs (double-reg)))
  (:temporary (:scs (non-descriptor-reg)) offset)
  (:result-types double-float)
  (:generator 5
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                               instance-pointer-lowtag))
    (inst lfdx value object offset)))

(define-vop ()
  (:translate %raw-instance-set/double)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg))
         (value :scs (double-reg)))
  (:arg-types * positive-fixnum double-float)
  (:temporary (:scs (non-descriptor-reg)) offset)
  (:generator 5
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                               instance-pointer-lowtag))
    (inst stfdx value object offset)))

(define-vop ()
  (:translate %raw-instance-ref/complex-single)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg)))
  (:arg-types * positive-fixnum)
  (:results (value :scs (complex-single-reg)))
  (:temporary (:scs (non-descriptor-reg)) offset)
  (:result-types complex-single-float)
  (:generator 5
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                               instance-pointer-lowtag))
    (inst lfsx (complex-single-reg-real-tn value) object offset)
    (inst addi offset offset (/ n-word-bytes 2))
    (inst lfsx (complex-single-reg-imag-tn value) object offset)))

(define-vop ()
  (:translate %raw-instance-set/complex-single)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg))
         (value :scs (complex-single-reg)))
  (:arg-types * positive-fixnum complex-single-float)
  (:temporary (:scs (non-descriptor-reg)) offset)
  (:generator 5
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                               instance-pointer-lowtag))
    (inst stfsx (complex-single-reg-real-tn value) object offset)
    (inst addi offset offset (/ n-word-bytes 2))
    (inst stfsx (complex-single-reg-imag-tn value) object offset)))

(define-vop ()
  (:translate %raw-instance-ref/complex-double)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg)))
  (:arg-types * positive-fixnum)
  (:results (value :scs (complex-double-reg)))
  (:temporary (:scs (non-descriptor-reg)) offset)
  (:result-types complex-double-float)
  (:generator 5
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                               instance-pointer-lowtag))
    (inst lfdx (complex-double-reg-real-tn value) object offset)
    (inst addi offset offset n-word-bytes)
    (inst lfdx (complex-double-reg-imag-tn value) object offset)))

(define-vop ()
  (:translate %raw-instance-set/complex-double)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg))
         (value :scs (complex-double-reg)))
  (:arg-types * positive-fixnum complex-double-float)
  (:temporary (:scs (non-descriptor-reg)) offset)
  (:generator 5
    (inst sldi offset index (- word-shift n-fixnum-tag-bits))
    (inst addi offset offset (- (ash instance-slots-offset word-shift)
                               instance-pointer-lowtag))
    (inst stfdx (complex-double-reg-real-tn value) object offset)
    (inst addi offset offset n-word-bytes)
    (inst stfdx (complex-double-reg-imag-tn value) object offset)))
