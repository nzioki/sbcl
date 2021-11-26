/*
 * C half of code-component allocator for Lisp with gencgc.
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

#include "sbcl.h"
#include "alloc.h"
#include "thread.h"
#include "getallocptr.h"
#include "genesis/code.h"

lispobj* atomic_bump_static_space_free_ptr(int nbytes)
{
    gc_assert((nbytes & LOWTAG_MASK) == 0);
    lispobj* claimed_ptr = static_space_free_pointer;
    do {
        lispobj* new = (lispobj*)((char*)claimed_ptr + nbytes);
        // Fail if space exhausted or bogusly wrapped around
        if (new > (lispobj*)STATIC_SPACE_END || new < claimed_ptr) return 0;
        lispobj* actual_old = __sync_val_compare_and_swap(&static_space_free_pointer,
                                                          claimed_ptr, new);
        if (actual_old == claimed_ptr) return claimed_ptr;
        claimed_ptr = actual_old;
    } while (1);
}

// Work space for the deterministic allocation profiler.
// Only supported on x86-64, but the variables are always referenced
// to reduce preprocessor conditionalization.
os_vm_address_t alloc_profile_buffer; // array of counters
static size_t profile_buffer_size;
lispobj alloc_profile_data;           // SIMPLE-VECTOR of <code-component,PC>
int alloc_profiling;              // enabled flag

#ifdef LISP_FEATURE_GENCGC
#ifdef LISP_FEATURE_SB_THREAD
/* This lock is used to protect non-thread-local allocation. */
#ifdef LISP_FEATURE_WIN32
CRITICAL_SECTION code_allocator_lock, alloc_profiler_lock;
#else
static pthread_mutex_t code_allocator_lock = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t alloc_profiler_lock = PTHREAD_MUTEX_INITIALIZER;
#endif
#endif
lispobj alloc_code_object (unsigned total_words)
{
    struct thread *th = get_sb_vm_thread();
#if defined(LISP_FEATURE_X86_64) && !defined(LISP_FEATURE_WIN32)
#  define REQUIRE_GC_INHIBIT 0
#else
#  define REQUIRE_GC_INHIBIT 1
#endif
#if REQUIRE_GC_INHIBIT
    /* It used to be that even on gencgc builds the
     * ALLOCATE-CODE-OBJECT VOP did all this initialization within
     * pseudo atomic. Here, we rely on gc being inhibited. */
    if (read_TLS(GC_INHIBIT, th) == NIL)
        lose("alloc_code_object called with GC enabled.");
#endif

    /* Allocations of code are all serialized. We might also acquire
     * free_pages_lock depending on availability of space in the region */
    int result = thread_mutex_lock(&code_allocator_lock);
    gc_assert(!result);
    struct code *code = (struct code *)
      lisp_alloc(&code_region, total_words*N_WORD_BYTES, CODE_PAGE_TYPE, th);
    result = thread_mutex_unlock(&code_allocator_lock);
    gc_assert(!result);
    THREAD_JIT(0);

    code->header = ((uword_t)total_words << CODE_HEADER_SIZE_SHIFT) | CODE_HEADER_WIDETAG;
    code->boxed_size = 0;
    code->debug_info = 0;
    ((lispobj*)code)[total_words-1] = 0; // zeroize the simple-fun table count
    THREAD_JIT(1);

    return make_lispobj(code, OTHER_POINTER_LOWTAG);
}
void close_code_region() {
    __attribute__((unused)) int result = thread_mutex_lock(&code_allocator_lock);
    gc_assert(!result);
    ensure_region_closed(&code_region, CODE_PAGE_TYPE);
    thread_mutex_unlock(&code_allocator_lock);
}
#endif

#include <stdio.h>
#include "genesis/vector.h"

// Counters 0 and 1 are reserve for variable-size allocations
// (hit count and total size) that overflow the maximum counter index.
// Counter 2 is reserved for fixed-size allocations.
// Constant-size allocations consume 1 entry (hit count)
// Variable-size consume 2 (hit count and total size).
unsigned int alloc_profile_n_counters = 3;
unsigned int max_alloc_point_counters;

void allocation_profiler_start()
{
    int __attribute__((unused)) ret = thread_mutex_lock(&alloc_profiler_lock);
    gc_assert(ret == 0);
    if (!alloc_profiling && simple_vector_p(alloc_profile_data)) {
        max_alloc_point_counters = vector_len(VECTOR(alloc_profile_data))/2;
        size_t size = N_WORD_BYTES * max_alloc_point_counters;
        os_vm_address_t old_buffer = 0;
        if (size != profile_buffer_size) {
            profile_buffer_size = size;
            old_buffer = alloc_profile_buffer;
            alloc_profile_buffer = os_allocate(size);
            printf("using %d cells (0x%"OBJ_FMTX" bytes) for profile buffer @ %p\n",
                   max_alloc_point_counters, (lispobj)size, alloc_profile_buffer);
        }
        alloc_profiling = 1;
        int n = 0;
        struct thread* th;
        for_each_thread(th) {
            th->profile_data = (uword_t*)alloc_profile_buffer;
            ++n;
        }
        printf("allocation profiler: %d thread%s\n", n, n>1?"s":"");
        if (old_buffer) {
            // Thread-safely switching buffers would entail lazy reclamation
            // of the old one. Just don't use the interface functions
            // when any thread might be looking at the old buffer.
            printf("WARNING: Unsafely changed alloc profile buffer\n");
            os_deallocate(alloc_profile_buffer, profile_buffer_size);
        }
    } else {
        fprintf(stderr, alloc_profiling ?
                "allocation profiler already started\n" :
                "profile metadata not created\n");
    }
    ret = thread_mutex_unlock(&alloc_profiler_lock);
    gc_assert(ret == 0);
    fflush(stdout);
}

// This is not exactly threadsafe. Don't try anything fancy.
void allocation_profiler_stop()
{
    int __attribute__((unused)) ret = thread_mutex_lock(&alloc_profiler_lock);
    gc_assert(ret == 0);
    if (alloc_profiling) {
        alloc_profiling = 0;
        struct thread* th;
        for_each_thread(th) {
            th->profile_data = 0;
        }
    } else {
        fprintf(stderr, "allocation profiler not started\n");
    }
    ret = thread_mutex_unlock(&alloc_profiler_lock);
    gc_assert(ret == 0);
#if 0
    if (warning_issued) {
        fprintf(stderr, "allocation profile needed %d counters\n",
                alloc_profile_n_counters);
        warning_issued = 0;
    }
#endif
}

#ifdef LISP_FEATURE_METASPACE
#include "gc-private.h"
lispobj valid_metaspace_ptr_p(void* addr)
{
    struct slab_header* slab = (void*)ALIGN_DOWN((lispobj)addr, METASPACE_SLAB_SIZE);
    fprintf(stderr, "slab base %p chunk_size %d capacity %d\n", slab, slab->chunksize, slab->capacity);
    if (!slab->capacity) return 0;
    lispobj slab_end = (lispobj)slab + METASPACE_SLAB_SIZE;
    int index = (slab_end - (lispobj)addr) / slab->chunksize;
    //    for(int i=0; i<slab->capacity; ++i) fprint(stderr, "goober @ %p\n", slab_end - (1+i)*chunksize);
    //    fprintf(stderr, "index=%d\n", index);
    if (index < slab->capacity) {
        lispobj* obj_base = (lispobj*)(slab_end - (index+1)*slab->chunksize);
        if (widetag_of(obj_base) == INSTANCE_WIDETAG) {
            fprintf(stderr, "word @ %p is good\n", obj_base);
            return (lispobj)obj_base;
        }
    }
    return 0;
}
#endif
