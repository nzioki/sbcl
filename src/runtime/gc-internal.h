/*
 * garbage collection - shared definitions for modules "inside" the GC system
 *
 * Despite the preceding claim, this header is a bit of a mashup of things
 * that are "internal to strictly GC" vs "for all SBCL-internal C code"
 * as opposed to gc.h which is some kind of external API,
 * though it's unclear for what, since hardly anything includes it.
 * GC-internal pieces that don't need to be revealed more widely
 * should be declared in 'gc-private.h'
 */

/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * This software is derived from the CMU CL system, which was
 * written at Carnegie Mellon University and released into the
 * public domain. The software is in the public domain and is
 * provided with absolutely no warranty. See the COPYING and CREDITS
 * files for more information.
 */

#ifndef _GC_INTERNAL_H_
#define _GC_INTERNAL_H_

#include "genesis/code.h"
#include "genesis/simple-fun.h"
#include "thread.h"
#include "interr.h" /* for lose() */

extern const char *widetag_names[];

/// Enable extra debug-only checks if DEBUG
#ifdef DEBUG
# define gc_dcheck(ex) gc_assert(ex)
#else
# define gc_dcheck(ex) ((void)0)
#endif

/// Disable all assertions if NDEBUG
#ifdef NDEBUG
# define gc_assert(ex) ((void)0)
# define gc_assert_verbose(ex, fmt, ...) ((void)0)
#else
# define gc_assert(ex)                                                 \
do {                                                                   \
    if (!(ex)) gc_abort();                                             \
} while (0)
# define gc_assert_verbose(ex, fmt, ...)                               \
do {                                                                   \
    if (!(ex)) {                                                       \
        fprintf(stderr, fmt, ## __VA_ARGS__);                          \
        gc_abort();                                                    \
    }                                                                  \
} while (0)
#endif

#define gc_abort()                                                     \
  lose("GC invariant lost, file \"%s\", line %d\n", __FILE__, __LINE__)

#ifdef LISP_FEATURE_GENCGC
#include "gencgc-internal.h"
#else
#include "cheneygc-internal.h"
#endif

#include "align.h"

// Offset from an fdefn raw address to the underlying simple-fun,
// if and only if it points to a simple-fun.
#if defined(LISP_FEATURE_SPARC) || defined(LISP_FEATURE_ARM)
#define FUN_RAW_ADDR_OFFSET 0
#else
#define FUN_RAW_ADDR_OFFSET (offsetof(struct simple_fun, code) - FUN_POINTER_LOWTAG)
#endif

// For x86[-64], a simple-fun or closure's "self" slot is a fixum
// On other backends, it is a lisp ointer.
#if defined(LISP_FEATURE_X86) || defined(LISP_FEATURE_X86_64)
#define FUN_SELF_FIXNUM_TAGGED 1
#else
#define FUN_SELF_FIXNUM_TAGGED 0
#endif

/* Code component trailer words:
 *                                                   v code size
 *      | fun_offset | fun_offset | .... | N-entries |
 *                                       ^
 *                 fun_table pointer ---/
 *
 * The fun_table pointer is aligned at a 4-byte boundary.
 */
static inline unsigned int*
code_fun_table(struct code* code) {
  return (unsigned int*)((char*)code
                         + code_header_words(code->header) * N_WORD_BYTES
                         + fixnum_value(code->code_size) - sizeof (uint16_t));
}
static inline unsigned short
code_n_funs(struct code* code) {
    // immobile space filler objects appear to be code but have no simple-funs.
    // Should probably consider changing the widetag to FILLER_WIDETAG.
    return (code_header_words(code->header) > 2)
        ? *((unsigned short*)code_fun_table(code)) : 0;
}

#define is_vector_subtype(header, val) ((HeaderValue(header) & 3) == subtype_##val)

// Iterate over the native pointers to each function in 'code_var'
// offsets are stored as the number of bytes into the instructions
// portion of the code object at which the simple-fun object resides.
// We use bytes, not words, because that's what the COMPUTE-FUN vop expects.
#define for_each_simple_fun(index_var,fun_var,code_var,assertp,guts)        \
  { int _nfuns_ = code_n_funs(code_var);                                    \
    if (_nfuns_ > 0) {                                                      \
      char *_insts_ = (char*)(code_var) +                                   \
        (code_header_words((code_var)->header)<<WORD_SHIFT);                \
      int index_var = 0;                                                    \
      unsigned int* _offsets_ = code_fun_table(code_var) - 1;               \
      do {                                                                  \
       struct simple_fun* fun_var                                           \
           = (struct simple_fun*)(_insts_ + _offsets_[-index_var]);         \
       if (assertp)                                                         \
         gc_assert(widetag_of(fun_var->header)==SIMPLE_FUN_WIDETAG);        \
       guts ;                                                               \
      } while (++index_var < _nfuns_);                                      \
  }}

#define SIMPLE_FUN_SCAV_START(fun_ptr) &fun_ptr->name
#define SIMPLE_FUN_SCAV_NWORDS(fun_ptr) ((lispobj*)fun_ptr->code - &fun_ptr->name)

/* values for the *_alloc_* parameters, also see the commentary for
 * struct page in gencgc-internal.h. These constants are used in gc-common,
 * so they can't easily be made gencgc-only */
#define FREE_PAGE_FLAG        0
/* Note: MAP-ALLOCATED-OBJECTS expects this value to be 1 */
#define BOXED_PAGE_FLAG       1
#define UNBOXED_PAGE_FLAG     2
#define OPEN_REGION_PAGE_FLAG 8
#define CODE_PAGE_TYPE        (BOXED_PAGE_FLAG|UNBOXED_PAGE_FLAG)

extern sword_t (*sizetab[256])(lispobj *where);
#define OBJECT_SIZE(header,where) \
  (is_cons_half(header)?2:sizetab[widetag_of(header)](where))

lispobj *gc_search_space3(void *pointer, lispobj *start, void *limit);
static inline lispobj *gc_search_space(lispobj *start, void *pointer) {
    return gc_search_space3(pointer,
                            start,
                            (void*)(1+((lispobj)pointer | LOWTAG_MASK)));
}

struct vector *symbol_name(lispobj*);

extern void scrub_control_stack(void);
extern void scrub_thread_control_stack(struct thread *);

#ifdef LISP_FEATURE_X86
void gencgc_apply_code_fixups(struct code *old_code, struct code *new_code);
#else
#define gencgc_apply_code_fixups(ignore1,ignore2)
#endif

#include "fixnump.h"

#if N_WORD_BITS == 32
# define SIMPLE_ARRAY_WORD_WIDETAG SIMPLE_ARRAY_UNSIGNED_BYTE_32_WIDETAG
#elif N_WORD_BITS == 64
# define SIMPLE_ARRAY_WORD_WIDETAG SIMPLE_ARRAY_UNSIGNED_BYTE_64_WIDETAG
#endif

extern void
instance_scan(void (*proc)(lispobj*, sword_t, uword_t),
              lispobj *instance_ptr, sword_t n_words,
              lispobj bitmap, uword_t arg);

#ifdef LISP_FEATURE_COMPACT_INSTANCE_HEADER
static inline lispobj funinstance_layout(lispobj* funinstance_ptr) { // native ptr
    return instance_layout(funinstance_ptr);
}
static inline lispobj function_layout(lispobj* fun_ptr) { // native ptr
    return instance_layout(fun_ptr);
}
static inline void set_function_layout(lispobj* fun_ptr, lispobj layout) {
    instance_layout(fun_ptr) = layout;
}
#else
static inline lispobj funinstance_layout(lispobj* instance_ptr) { // native ptr
    // first 4 words are: header, trampoline, fin-fun, layout
    return instance_ptr[3];
}
// No layout in simple-fun or closure, because there are no free bits
static inline lispobj function_layout(lispobj* fun_ptr) { // native ptr
    return 0;
}
static inline void set_function_layout(lispobj* fun_ptr, lispobj layout) {
    lose("Can't assign layout");
}
#endif

#include "genesis/bignum.h"
extern boolean positive_bignum_logbitp(int,struct bignum*);

#ifdef LISP_FEATURE_IMMOBILE_CODE

/* The callee_lispobj of an fdefn is the value in the 'raw_addr' slot to which
 * control transfer occurs, but cast as a simple-fun or code component.
 * It can momentarily disagree with the 'fun' slot when assigning a new value.
 * Pointer tracing should almost always examine both slots, as scav_fdefn() does.
 * If the raw_addr value points to read-only space, the callee is just raw_addr
 * itself, which either looks like a simple-fun or a fixnum depending on platform.
 * It is not critical that this exceptional situation be consistent by having
 * a pointer lowtag because it only affects print_otherptr() and verify_space()
 * neither of which materially impact garbage collection. */

extern lispobj fdefn_callee_lispobj(struct fdefn *fdefn);

#else

static inline lispobj points_to_asm_routine_p(uword_t ptr) {
# if defined(LISP_FEATURE_IMMOBILE_SPACE)
    // Lisp assembly routines are in varyobj space, not readonly space
    extern unsigned int asm_routines_end;
    return ptr < (uword_t)asm_routines_end;
# else
    return READ_ONLY_SPACE_START <= ptr && ptr < READ_ONLY_SPACE_END;
# endif
}
static inline lispobj fdefn_callee_lispobj(struct fdefn *fdefn) {
    return (lispobj)fdefn->raw_addr -
      (points_to_asm_routine_p((uword_t)fdefn->raw_addr) ? 0 : FUN_RAW_ADDR_OFFSET);
}

#endif

#ifdef LISP_FEATURE_IMMOBILE_SPACE
#include "genesis/layout.h"
#define LAYOUT_SIZE (sizeof (struct layout)/N_WORD_BYTES)
/// First 5 layouts: T, FUNCTION, STRUCTURE-OBJECT, LAYOUT, PACKAGE
/// (These #defines ought to be emitted by genesis)
#define LAYOUT_OF_FUNCTION ((FIXEDOBJ_SPACE_START+1*LAYOUT_ALIGN)|INSTANCE_POINTER_LOWTAG)
#define LAYOUT_OF_LAYOUT   ((FIXEDOBJ_SPACE_START+3*LAYOUT_ALIGN)|INSTANCE_POINTER_LOWTAG)
#define LAYOUT_OF_PACKAGE  ((FIXEDOBJ_SPACE_START+4*LAYOUT_ALIGN)|INSTANCE_POINTER_LOWTAG)
#endif

#endif /* _GC_INTERNAL_H_ */
