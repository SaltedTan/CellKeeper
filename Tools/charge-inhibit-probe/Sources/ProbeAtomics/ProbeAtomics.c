#include "ProbeAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct probe_latch {
    _Atomic uint64_t sequence;
    _Atomic uint64_t time_bits;
};

probe_latch *probe_latch_create(void) {
    probe_latch *latch = malloc(sizeof *latch);
    if (latch == NULL) {
        return NULL;
    }
    atomic_init(&latch->sequence, 0);
    atomic_init(&latch->time_bits, 0);
    return latch;
}

void probe_latch_destroy(probe_latch *latch) {
    free(latch);
}

void probe_latch_record(probe_latch *latch, double time) {
    uint64_t bits;
    memcpy(&bits, &time, sizeof bits);
    atomic_store_explicit(&latch->time_bits, bits, memory_order_relaxed);
    atomic_fetch_add_explicit(&latch->sequence, 1, memory_order_release);
}

uint64_t probe_latch_read(probe_latch *latch, double *time) {
    uint64_t sequence = atomic_load_explicit(&latch->sequence, memory_order_acquire);
    if (time != NULL) {
        uint64_t bits = atomic_load_explicit(&latch->time_bits, memory_order_relaxed);
        memcpy(time, &bits, sizeof *time);
    }
    return sequence;
}
