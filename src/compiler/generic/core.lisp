;;;; stuff that knows how to load compiled code directly into core

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-C")

;;; A CORE-OBJECT structure holds the state needed to resolve cross-component
;;; references during in-core compilation.
(defstruct (core-object
            (:constructor make-core-object (ephemeral))
            (:print-object (lambda (x s)
                             (print-unreadable-object (x s :type t :identity t))))
            (:copier nil))
  ephemeral
  ;; A hashtable translating ENTRY-INFO structures to the corresponding actual
  ;; FUNCTIONs for functions in this compilation.
  (entry-table (make-hash-table :test 'eq) :type hash-table)
  ;; A list of all the DEBUG-INFO objects created, kept so that we can
  ;; backpatch with the source info.
  (debug-info () :type list))


;;; Map of code-component -> list of PC offsets at which allocations occur.
;;; This table is needed in order to enable allocation profiling.
(define-load-time-global *allocation-patch-points*
  (make-hash-table :test 'eq :weakness :key :synchronized t))

;;; Point FUN's 'self' slot to FUN.
;;; FUN must be pinned when calling this.
#-darwin-jit ; done entirely by C for #+darwin-jit
(defmacro assign-simple-fun-self (fun)
  `(let* ((fun ,fun)
          (self
           ;; a few architectures store the untagged address of the entrypoint in 'self'
           #+(or arm64 ppc64 x86 x86-64)
           (%make-lisp-obj
            (truly-the word (+ (get-lisp-obj-address fun)
                               (ash sb-vm:simple-fun-insts-offset sb-vm:word-shift)
                               (- sb-vm:fun-pointer-lowtag))))
           ;; all others store the function itself (what else?) in 'self'
           #-(or arm64 ppc64 x86 x86-64) fun))
     (setf (sb-vm::%simple-fun-self fun) self)))

(flet ((fixup (code-obj offset name kind flavor-id real-code-obj callees
               &aux (flavor (aref +fixup-flavors+ flavor-id)))
         ;; NAME depends on the kind and flavor of fixup.
         ;; CODE-OBJ must already be pinned in order to legally call this.
         ;; One call site that reaches here is below at MAKE-CORE-COMPONENT
         ;; and the other is LOAD-CODE, both of which pin the code.
         (sb-vm:fixup-code-object
                 code-obj offset
                 (fixup-flavor-case flavor-id
                   (:assembly-routine
                    (let* ((asm-code *assembler-routines*)
                           (index (if (fixnump name)
                                      name
                                      (or (cddr (gethash name (sb-fasl::%asm-routine-table asm-code)))
                                          (error "Unknown asm routine ~S" name)))))
                      (sap-int (sap+ (code-instructions asm-code)
                                     (aref *asm-routine-offsets* index)))))
                   (:alien-code-linkage-index (sb-impl::ensure-alien-linkage-index name nil))
                   (:alien-data-linkage-index (sb-impl::ensure-alien-linkage-index name t))
                   (:foreign (foreign-symbol-address name))
                   (:foreign-dataref (foreign-symbol-address name t))
                   #+linkage-space
                   ((:linkage-cell :linkage-cell-ud)
                    (let* ((quiet (eq flavor :linkage-cell))
                           (index (ensure-linkage-index name quiet)))
                      (unless (permanent-fname-p name) (setq callees (adjoin index callees)))
                      ;; machine-dependent fixup doesn't want to know which flavor was used
                      (setq flavor :linkage-cell)
                      index))
                   (:code-object (get-lisp-obj-address real-code-obj))
                   #+sb-thread (:symbol-tls-index (ensure-symbol-tls-index name))
                   (:layout (get-lisp-obj-address
                             (if (symbolp name) (find-layout name) name)))
                   (:layout-id (layout-id name))
                   (:card-table-index-mask (extern-alien "gc_card_table_nbits" int))
                   (:immobile-symbol (get-lisp-obj-address name))
                   ;; It is legal to take the address of symbol-value only if the
                   ;; value is known to be an immobile object
                   ;; (whose address we don't want to wire in).
                   (:symbol-value (get-lisp-obj-address (symbol-global-value name)))
                   (t (bug "bad fixup flavor ~s" flavor)))
                 kind flavor)
         callees)
       (finish-fixups (code-obj callees other-fixups)
         (declare (ignorable code-obj callees))
         (setf (sb-vm::%code-fixups code-obj)
               #+linkage-space (join-varint-streams (pack-code-fixup-locs callees) other-fixups)
               #-linkage-space other-fixups)
         ;; Assign all SIMPLE-FUN-SELF slots unless #+darwin-jit in which case the simple-funs
         ;; are assigned by jit_memcpy_codeblob()
         #-darwin-jit
         (dotimes (i (code-n-entries code-obj))
           (let ((fun (%code-entry-point code-obj i)))
             (assign-simple-fun-self fun)
             ;; And maybe store the layout in the high half of the header
             #+(and compact-instance-header x86-64)
             (setf (sap-ref-32 (int-sap (get-lisp-obj-address fun))
                               (- 4 sb-vm:fun-pointer-lowtag))
                   (truly-the (unsigned-byte 32)
                              (get-lisp-obj-address #.(find-layout 'function))))))
         ;; And finally, make the memory range executable.
         ;; x86 doesn't need it, and darwin-jit doesn't do it because the
         ;; temporary object is not executable.
         #-(or x86 x86-64 darwin-jit) (sb-vm:sanctify-for-execution code-obj)
         nil))

  (defun apply-fasl-fixups (code-obj fixups index count real-code-obj
                            &aux (end (1- (+ index count))))
    (let ((retained-fixups (svref fixups index))
          callees)
      (incf index)
      (awhen (svref fixups index)
        (setf (gethash code-obj *allocation-patch-points*) it))
      (loop
        (when (>= index end) (return))
        (binding* (((offset kind flavor-id data)
                    (sb-fasl::!unpack-fixup-info (svref fixups (incf index))))
                   (name (if (eql 0 data) (svref fixups (incf index)) data)))
          (setq callees (fixup code-obj offset name kind flavor-id real-code-obj callees))))
      (finish-fixups code-obj callees retained-fixups)))

  (defun apply-core-fixups (code-obj fixup-notes retained-fixups real-code-obj)
    (declare (list fixup-notes))
    (let (callees)
      (dolist (note fixup-notes)
        (let ((fixup (fixup-note-fixup note))
              (offset (fixup-note-position note)))
          (setq callees
                (fixup code-obj offset
                       (fixup-name fixup)
                       (fixup-note-kind note)
                       (encoded-fixup-flavor (fixup-flavor fixup))
                       real-code-obj callees))))
      (finish-fixups code-obj callees retained-fixups))))

;;; Dump a component to core. We pass in the assembler fixups, code
;;; vector and node info.
(defun make-core-component (component segment length fixup-notes alloc-points object)
  (declare (type component component)
           (type segment segment)
           (type index length)
           (list fixup-notes)
           (type core-object object))
  (binding*
      ((debug-info (debug-info-for-component component))
       (2comp (component-info component))
       (constants (ir2-component-constants 2comp))
       (n-boxed-words (length constants))
       (boxed-data
        ;; <header, boxed_size, debug_info, fixups> are absent from the simple-vector
        (or #+darwin-jit
            (make-array (- n-boxed-words sb-vm:code-constants-offset) :initial-element 0)))
       (const-patch-start-index sb-vm:code-constants-offset)
       ;; Ensure existence of FDEFNs before allocating code. This potentially reduces
       ;; the number of old->young pointers when assigning boxed words.
       (nil
        (do ((index const-patch-start-index (1+ index)))
            ((>= index n-boxed-words))
          (let ((const (aref constants index)))
            (when (typep const '(cons (eql :fdefinition)))
              (setf (second const) (find-or-create-fdefn (second const)))))))
       (retained-fixups (sb-c::pack-fixups-for-reapplication fixup-notes))
       ((code-obj total-nwords)
        (allocate-code-object (component-mem-space component)
                              (align-up n-boxed-words code-boxed-words-align)
                              length))
       (bytes
        (the (simple-array assembly-unit 1) (segment-contents-as-vector segment)))
       (n-simple-funs (length (ir2-component-entries 2comp)))
       (named-call-fixups nil)
       (real-code-obj code-obj))
    (declare (ignorable boxed-data))
    (sb-fasl::with-writable-code-instructions
        (code-obj total-nwords debug-info n-simple-funs)
        :copy (%byte-blt bytes 0 (code-instructions code-obj) 0 (length bytes))
        :fixup (setq named-call-fixups
                     (apply-core-fixups code-obj fixup-notes retained-fixups real-code-obj)))

    (when alloc-points
      #+(and x86-64 sb-thread)
      (if (= (extern-alien "alloc_profiling" int) 0) ; record the object for later
          (setf (gethash code-obj *allocation-patch-points*) alloc-points)
          (funcall 'sb-aprof::patch-code code-obj alloc-points nil)))

    (push debug-info (core-object-debug-info object))

    ;; Don't need code pinned now
    ;; (It will implicitly be pinned on the conservatively scavenged backends)
    (macrolet ((set-boxed-word (i val)
                 #+darwin-jit
                 `(setf (svref boxed-data (- ,i ,sb-vm:code-constants-offset)) ,val)
                 #-darwin-jit
                 `(setf (code-header-ref code-obj ,i) ,val)))

      (let* ((entries (ir2-component-entries 2comp))
             (fun-index (length entries)))
        (dolist (entry-info entries)
          (let ((fun (%code-entry-point code-obj (decf fun-index))))
            (aver (functionp fun)) ; in case %CODE-ENTRY-POINT returns NIL
            (setf (gethash entry-info (core-object-entry-table object)) fun))))

      (do ((index const-patch-start-index (1+ index)))
          ((>= index n-boxed-words))
        (let ((const (aref constants index)))
          (set-boxed-word index
                (if (constant-p const)
                    (constant-value const)
                    (destructuring-bind (kind payload) const
                      (ecase kind
                        (:fdefinition payload)
                        (:entry
                         (the function (gethash (leaf-info payload)
                                                (core-object-entry-table object))))
                        (:known-fun (%coerce-name-to-fun payload))))))))

      #+darwin-jit (assign-code-constants code-obj boxed-data))

    (sb-fasl::possibly-log-new-code code-obj "core")))

;;; Call the top level lambda function dumped for ENTRY, returning the
;;; values. ENTRY may be a :TOPLEVEL-XEP functional.
(defun core-call-toplevel-lambda (entry object)
  (declare (type functional entry) (type core-object object))
  (funcall (or (gethash (leaf-info entry)
                        (core-object-entry-table object))
               (error "Unresolved forward reference."))))

;;; Backpatch all the DEBUG-INFOs dumped so far with the specified
;;; SOURCE-INFO list. We also check that there are no outstanding
;;; forward references to functions.
(defun fix-core-source-info (info object &optional function)
  (declare (type core-object object))
  (declare (type (or null function) function))
  (let ((source (debug-source-for-info info :function function)))
    (dolist (info (core-object-debug-info object))
      (setf (debug-info-source info) source)))
  (setf (core-object-debug-info object) nil)
  (values))

;;; Return a behaviorally identical copy of CODE which is used for TRACE
;;; in "funobj encapsulation" mode where we just switch an entry point
;;; so that it jumps to a tracing routine and then back again.
;;; The code that gets copied is just the tracing wrapper.
;;; See the example at COMPILE-FUNOBJ-ENCAPSULATION in ntrace
#+(or ppc64 x86 x86-64)
(defun copy-code-object (code)
  ;; Must have one simple-fun
  (aver (= (code-n-entries code) 1))
  (let* ((nbytes (code-object-size code))
         (boxed (code-header-words code)) ; word count
         (unboxed (- nbytes (ash boxed sb-vm:word-shift))) ; byte count
         (copy (allocate-code-object :dynamic boxed unboxed)))
    (with-pinned-objects (code copy)
      (%byte-blt (code-instructions code) 0 (code-instructions copy) 0 unboxed)
      ;; copy boxed constants so that the fixup step (if needed) sees the 'fixups'
      ;; slot from the new object.
      (loop for i from 2 below boxed
            do (setf (code-header-ref copy i) (code-header-ref code i)))
      ;; x86 needs to fixup instructions that reference code constants,
      ;; and the jmp to TAIL-CALL-VARIABLE
      #+x86 (alien-funcall (extern-alien "gencgc_apply_code_fixups" (function void unsigned unsigned))
                           (- (get-lisp-obj-address code) sb-vm:other-pointer-lowtag)
                           (- (get-lisp-obj-address copy) sb-vm:other-pointer-lowtag))
      (assign-simple-fun-self (%code-entry-point copy 0)))
    copy))

;;; Note that it is critical that the new code object not be movable after
;;; copying in unboxed bytes and prior to fixing up those bytes.
;;; Why: suppose the object has a jump table initially filled with addends of
;;; 0x1000, 0x1100, 0x1200 representing the label offsets. If GC moves the object,
;;; it adds the amount of movement to those labels. If it moves by, say +0x5000,
;;; then the addends get mangled into 0x6000, 0x6100, 0x6200.
;;; When we then add those addends to the virtual address of the code to
;;; perform fixup application, the resulting addresses are all wrong.
;
;;; While GC might be made to use a heuristic to decide whether the label offsets
;;; had been fixed up at all, it would be fragile nonetheless, because an offset
;;; could theoretically resemble a valid address on machines where code resides
;;; at low addresses in an object whose size is large. e.g. for an object which
;;; spans the range 0x10000..0x30000 in memory, and the word 0x11000 in the jump
;;; table, does that word represent an already-fixed-up label offset of 0x01000,
;;; or an un-fixed-up value which needs to become 0x21000 ? It's ambiguous.
;;; We could add 1 bit to the code object signifying that fixups had beeen applied
;;; for the first time. But that complication is not needed, as long as we keep the
;;; code pinned. That suffices because prior to copying in anything, all bytes
;;; are 0, so the jump table count is 0.
;;; Similar considerations pertain to x86[-64] fixups within the machine code.

(defun code-header/trailer-adjust (code-obj expected-nwords)
  (declare (ignorable expected-nwords))
  ;; Serial# shares a word with the jump-table word count,
  ;; so we can't assign serial# until after all raw bytes are copied in.
  ;; Do we need unique IDs on the various strange kind of code blobs? These would
  ;; include code from MAKE-TRAMPOLINE, ENCAPSULATE-FUNOBJ, MAKE-BPT-LRA.
  (let* ((serialno (ldb (byte (byte-size sb-vm::code-serialno-byte) 0)
                        (atomic-incf *code-serialno*)))
         (insts (code-instructions code-obj))
         (jumptable-word (sap-ref-word insts 0)))
    (aver (zerop (ash jumptable-word -14)))
    (setf (sap-ref-word insts 0) ; insert serialno
          (logior (ash serialno (byte-position sb-vm::code-serialno-byte))
                  jumptable-word)))
  #+64-bit
  (let ((base (sap+ (int-sap (get-lisp-obj-address code-obj)) (- sb-vm:other-pointer-lowtag)))
        (physical-nwords ; upper 4 bytes of the header word
         (ash (get-header-data code-obj) -24)))
    (when (/= physical-nwords expected-nwords)
      ;; Oversized allocation must be exactly 2 words more than requested
      (aver (= (- physical-nwords 2) expected-nwords))
      ;; Point just beyond the trailer word (physically and where it should be)
      (let* ((new-trailer (sap+ base (ash physical-nwords sb-vm:word-shift)))
             (old-trailer (sap+ base (ash (- physical-nwords 2) sb-vm:word-shift)))
             (trailer-length (sap-ref-16 old-trailer -2)) ; in bytes
             (trailer-nelements (floor trailer-length 4)))
        ;; this is a memmove() and memset()
        (dotimes (i trailer-nelements)
          ;; Transfer 4 bytes per element (uint32_t), highest address first
          ;; since we're moving upward in memory.
          (let ((offset (* (1+ i) -4)))
            (setf (sap-ref-32 new-trailer offset) (sap-ref-32 old-trailer offset) )))
        ;; Zeroize at most 4 elements in the "old" trailer. These will be the
        ;; items at the lowest addresses (the highest indices in negative order).
        ;; If there are fewer than 4 elements, then only zeroize that many.
        (loop for offset from (* trailer-nelements -4) by 4
              repeat (min trailer-nelements 4)
              do (setf (sap-ref-32 old-trailer offset) 0))
        ;; Increase the trailer length by 2 lispwords
        (incf (sap-ref-16 new-trailer -2) (* 2 sb-vm:n-word-bytes)))))
  ;; Enforce that the final unboxed data word is published to memory
  ;; before the debug-info is set.
  (sb-thread:barrier (:write)))

#+darwin-jit
(defun assign-code-constants (code data)
  (let* ((sb-vm::*pinned-objects* ; Pin DATA plus every element of it.
          (list* code data (nconc (coerce data 'list) sb-vm::*pinned-objects*))))
    (sb-vm::jit-copy-code-constants (get-lisp-obj-address code)
                                    (get-lisp-obj-address data))))
