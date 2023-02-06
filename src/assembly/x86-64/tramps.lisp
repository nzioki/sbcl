;;;; Undefined-function and closure trampoline definitions

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-VM")

(macrolet ((do-fprs (operation regset)
             (multiple-value-bind (mnemonic fpr-align)
                 (ecase regset
                   (:xmm (values 'movaps 16))
                   (:ymm (values 'vmovaps 32)))
               `(progn
                  ,@(loop for regno below 16
                       collect
                         (ecase operation
                           (push
                            `(inst ,mnemonic (ea ,(+ 8 (* regno fpr-align)) rsp-tn)
                                   (sb-x86-64-asm::get-fpr ,regset ,regno)))
                           (pop
                            `(inst ,mnemonic (sb-x86-64-asm::get-fpr ,regset ,regno)
                                   (ea ,(+ 8 (* regno fpr-align)) rsp-tn)))))))))
  ;; Caller will have allocated 512+64+256 bytes above the stack-pointer
  ;; prior to the CALL. Use that as the save area.
  (define-assembly-routine (save-ymm) ()
    (inst push rax-tn)
    (inst push rdx-tn)
    (inst mov rax-tn 7)
    (zeroize rdx-tn)
    ;; Zero the header
    (loop for i from (+ 512 24) by 8
          repeat 8
          do
          (inst mov (ea i rsp-tn) rdx-tn))
    (inst xsave (ea 24 rsp-tn))
    (inst pop rdx-tn)
    (inst pop rax-tn))
  (define-assembly-routine (restore-ymm) ()
    (inst push rax-tn)
    (inst push rdx-tn)
    (inst mov rax-tn 7)
    (zeroize rdx-tn)
    (inst xrstor (ea 24 rsp-tn))
    (inst pop rdx-tn)
    (inst pop rax-tn))
  ;; As above, but only 256 bytes of the save area are needed, the rest goes to waste.
  (define-assembly-routine (save-xmm (:export fpr-save)) ()
    fpr-save ; KLUDGE: this is element 4 of the entry point vector
    (do-fprs push :xmm))
  (define-assembly-routine (restore-xmm (:export fpr-restore)) ()
    fpr-restore ; KLUDGE: this is element 6 of the entry point vector
    (do-fprs pop :xmm)))

(define-assembly-routine (switch-to-arena (:return-style :raw)) ()
  (inst mov rsi-tn (ea rsp-tn)) ; explicitly  pass the return PC. RSI is a vop temp
  (with-registers-preserved (c)
    (pseudo-atomic ()
      #-system-tlabs (inst break halt-trap)
      #+system-tlabs (inst call (make-fixup "switch_to_arena" :foreign)))))

(macrolet ((def-routine-pair (name&options vars &body code)
             `(progn
                (symbol-macrolet ((system-tlab-p 0))
                  (define-assembly-routine ,name&options ,vars ,@code))
                ;; In absence of this feature, don't define extra routines.
                ;; (Don't want to have a way to mess things up)
                #+system-tlabs
                (symbol-macrolet ((system-tlab-p 2))
                  (define-assembly-routine
                      (,(symbolicate "SYS-" (car name&options)) . ,(cdr name&options))
                    ,vars ,@code)))))

(def-routine-pair (alloc-tramp) ()
  (with-registers-preserved (c)
    (inst mov rdi-tn (ea 16 rbp-tn))
    (inst mov rsi-tn system-tlab-p)
    (inst call (make-fixup "alloc" :foreign))
    (inst mov (ea 16 rbp-tn) rax-tn))) ; result onto stack

(def-routine-pair (list-alloc-tramp) () ; CONS, ACONS, LIST, LIST*
  (with-registers-preserved (c)
    (inst mov rdi-tn (ea 16 rbp-tn))
    (inst mov rsi-tn system-tlab-p)
    (inst call (make-fixup "alloc_list" :foreign))
    (inst mov (ea 16 rbp-tn) rax-tn))) ; result onto stack

(def-routine-pair (listify-&rest (:return-style :none)) ()
  (with-registers-preserved (c)
    (inst mov rdi-tn (ea 16 rbp-tn)) ; 1st C call arg
    (inst mov rsi-tn (ea 24 rbp-tn)) ; 2nd C call arg
    (inst mov rdx-tn system-tlab-p)
    (inst call (make-fixup "listify_rest_arg" :foreign))
    (inst mov (ea 24 rbp-tn) rax-tn)) ; result
  (inst ret 8)) ; pop one argument; the unpopped word now holds the result

(def-routine-pair (make-list (:return-style :none)) ()
  (with-registers-preserved (c)
    (inst mov rdi-tn (ea 16 rbp-tn)) ; 1st C call arg
    (inst mov rsi-tn (ea 24 rbp-tn)) ; 2nd C call arg
    (inst mov rdx-tn system-tlab-p)
    (inst call (make-fixup "make_list" :foreign))
    (inst mov (ea 24 rbp-tn) rax-tn)) ; result
  (inst ret 8)) ; pop one argument; the unpopped word now holds the result
)

(define-assembly-routine (alloc-funinstance) ()
  (with-registers-preserved (c)
    (inst mov rdi-tn (ea 16 rbp-tn))
    (inst call (make-fixup "alloc_funinstance" :foreign))
    (inst mov (ea 16 rbp-tn) rax-tn)))

;;; These routines are for the deterministic consing profiler.
;;; The C support routine's argument is the return PC.
(define-assembly-routine (enable-alloc-counter) ()
  (with-registers-preserved (c)
    (inst lea rdi-tn (ea 8 rbp-tn))
    (pseudo-atomic () (inst call (make-fixup "allocation_tracker_counted" :foreign)))))

(define-assembly-routine (enable-sized-alloc-counter) ()
  (with-registers-preserved (c)
    (inst lea rdi-tn (ea 8 rbp-tn))
    (pseudo-atomic () (inst call (make-fixup "allocation_tracker_sized" :foreign)))))

(define-assembly-routine (undefined-tramp (:return-style :none))
    ((:temp rax descriptor-reg rax-offset))
  (inst pop (ea n-word-bytes rbp-tn))
  (emit-error-break nil cerror-trap (error-number-or-lose 'undefined-fun-error) (list rax))
  (inst push (ea n-word-bytes rbp-tn))
  (inst jmp (ea (- (* closure-fun-slot n-word-bytes) fun-pointer-lowtag) rax)))

#+win32
(define-assembly-routine
    (undefined-alien-tramp (:return-style :none))
    ()
  (error-call nil 'undefined-alien-fun-error rbx-tn))

#-win32
(define-assembly-routine
    (undefined-alien-tramp (:return-style :none))
    ()
  ;; This routine computes into RBX the address of the linkage table entry that was called,
  ;; corresponding to the undefined alien function.
  (inst push rax-tn) ; save registers in case we want to see the old values
  (inst push rbx-tn)
  ;; load RAX with the PC after the call site
  (inst mov rax-tn (ea 16 rsp-tn))
  ;; load RBX with the signed 32-bit immediate from the call instruction
  (inst movsx '(:dword :qword) rbx-tn (ea -4 rax-tn))
  ;; The decoding seems scary, but it's actually not. Any C call-out instruction has
  ;; a 4-byte trailing operand, with the preceding byte being unique.
  ;; if at [PC-5] we see #x25 then it was a call with 32-bit mem addr
  ;; if ...              #xE8 then ...                32-bit offset
  ;; if ...              #x92 then it was "call *DISP(%r10)" where r10 is the table base
  #-immobile-space ; only non-relocatable alien linkage table can use "CALL [ABS]" form
  (progn (inst cmp :byte (ea -5 rax-tn) #x25)
         (inst jmp :e ABSOLUTE))
  #+immobile-space ; only relocatable alien linkage table can use "CALL rel32" form
  (progn (inst cmp :byte (ea -5 rax-tn) #xE8)
         (inst jmp :e RELATIVE)
         (inst cmp :byte (ea -5 rax-tn) #x92)
         (inst jmp :e ABSOLUTE))
  ;; failing those, assume RBX was valid. ("can't happen")
  (inst mov rbx-tn (ea rsp-tn)) ; restore pushed value of RBX
  (inst jmp trap)
  ABSOLUTE
  #-immobile-space (inst sub rbx-tn 8)
  #+immobile-space (inst lea rbx-tn (ea -8 r10-tn rbx-tn))
  (inst jmp TRAP)
  RELATIVE
  (inst add rbx-tn rax-tn)
  TRAP
  ;; XXX: why aren't we adding something to the stack pointer to balance the two pushes?
  ;; (I guess we can only THROW at this point, so it doesn't matter)
  (error-call nil 'undefined-alien-fun-error rbx-tn))

;;; the closure trampoline - entered when a global function is a closure
;;; and the function is called "by name" (normally, as when it is the
;;; head of a form) via an FDEFN. Register %RAX holds the fdefn address,
;;; but the simple-fun which underlies the closure expects %RAX to be the
;;; closure itself. So we grab the closure out of the fdefn pointed to,
;;; then jump to the simple-fun that the closure points to.
;;;
;;; Immobile code uses a different strategy to call a closure that has been
;;; installed as a globally named function. The fdefn contains a jump opcode
;;; to a tiny code component specific to the particular closure.
;;; The trampoline is responsible for loading RAX, since named calls don't.
;;; However, #+immobile-code might still need CLOSURE-TRAMP for any fdefn
;;; for which the compiler chooses not to use "direct" call convention.
(define-assembly-routine
    (closure-tramp (:return-style :none))
    ()
  (loadw rax-tn rax-tn fdefn-fun-slot other-pointer-lowtag)
  (inst jmp (object-slot-ea rax-tn closure-fun-slot fun-pointer-lowtag)))

#-compact-instance-header
(define-assembly-routine
    (funcallable-instance-tramp (:return-style :none))
    ()
  (loadw rax-tn rax-tn funcallable-instance-function-slot fun-pointer-lowtag)
  (inst jmp (object-slot-ea rax-tn closure-fun-slot fun-pointer-lowtag)))

(define-assembly-routine (ensure-symbol-hash (:return-style :raw)) ()
  (with-registers-preserved (lisp)
    (inst mov rdx-tn (ea 16 rbp-tn)) ; arg
    (call-static-fun 'ensure-symbol-hash 1)
    (inst mov (ea 16 rbp-tn) rdx-tn))) ; result to arg passing loc
