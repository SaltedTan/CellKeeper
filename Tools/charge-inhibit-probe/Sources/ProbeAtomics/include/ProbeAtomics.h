#ifndef PROBE_ATOMICS_H
#define PROBE_ATOMICS_H

#include <stdint.h>

/// A sequence number and the moment of the latest event, recorded by one
/// thread and read by others without a lock (C11 atomics). `watch` uses one
/// as its sleep latch: the sleep notification records into it and does
/// nothing else (code review r1 of #101, must 2).
typedef struct probe_latch probe_latch;

/// A new latch at sequence 0. Never fails on a working system; NULL if
/// memory runs out.
probe_latch *probe_latch_create(void);

void probe_latch_destroy(probe_latch *latch);

/// Records an event at `time`: stores the time, then advances the
/// sequence with release ordering. Lock-free; no I/O.
void probe_latch_record(probe_latch *latch, double time);

/// The sequence, read with acquire ordering, and the time recorded with
/// the latest event (into `time`, if not NULL).
uint64_t probe_latch_read(probe_latch *latch, double *time);

#endif
