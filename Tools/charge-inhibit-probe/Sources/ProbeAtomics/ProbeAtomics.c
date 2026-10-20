#include "ProbeAtomics.h"

#include <stdatomic.h>
#include <stdlib.h>

struct probe_log {
    double times[PROBE_LOG_CAPACITY];
    _Atomic uint32_t count;
    _Atomic bool overflowed;
};

probe_log *probe_log_create(void) {
    probe_log *log = calloc(1, sizeof *log);
    if (log == NULL) {
        return NULL;
    }
    atomic_init(&log->count, 0);
    atomic_init(&log->overflowed, false);
    return log;
}

void probe_log_destroy(probe_log *log) {
    free(log);
}

void probe_log_append(probe_log *log, double time) {
    // Only this writer changes count, so a relaxed load of it is exact.
    uint32_t count = atomic_load_explicit(&log->count, memory_order_relaxed);
    if (count >= PROBE_LOG_CAPACITY) {
        atomic_store_explicit(&log->overflowed, true, memory_order_release);
        return;
    }
    log->times[count] = time;
    atomic_store_explicit(&log->count, count + 1, memory_order_release);
}

uint32_t probe_log_count(probe_log *log) {
    return atomic_load_explicit(&log->count, memory_order_acquire);
}

double probe_log_time(probe_log *log, uint32_t index) {
    return log->times[index];
}

bool probe_log_overflowed(probe_log *log) {
    return atomic_load_explicit(&log->overflowed, memory_order_acquire);
}
