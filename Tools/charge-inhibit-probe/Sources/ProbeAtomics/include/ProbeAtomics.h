#ifndef PROBE_ATOMICS_H
#define PROBE_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

/// The most occurrences a log keeps; past that it only says it overflowed.
#define PROBE_LOG_CAPACITY 64

/// An append-only log of occurrence times, written by one thread and read by
/// others without a lock (C11 atomics). `watch` uses one as its sleep log:
/// the sleep notification appends to it and does nothing else (code review
/// r2 of #101, must D).
///
/// The single writer stores `times[count]` and then publishes `count + 1`
/// with release ordering; a reader loads `count` with acquire ordering and
/// then reads `times[0 ..< count]`, every one of which was written before
/// that release. So a reader's snapshot is always a coherent prefix of the
/// log: no torn pair, no time without its place.
typedef struct probe_log probe_log;

/// A new, empty log; NULL if memory runs out.
probe_log *probe_log_create(void);

void probe_log_destroy(probe_log *log);

/// For the single writer only: appends `time`. Past the capacity it appends
/// nothing and marks the log overflowed. Lock-free; no I/O.
void probe_log_append(probe_log *log, double time);

/// How many times the log holds (acquire).
uint32_t probe_log_count(probe_log *log);

/// The time at `index`, which must be below a count this thread has read.
double probe_log_time(probe_log *log, uint32_t index);

/// Whether an append found the log full (acquire). It is set only after
/// the log is full, so read it before the count.
bool probe_log_overflowed(probe_log *log);

/// A 64-bit value stored and loaded atomically: `watch`'s current question
/// generation, which the console writer reads without the run's lock (code
/// review r2 of #101, must B).
typedef struct probe_value probe_value;

/// A new value of 0; NULL if memory runs out.
probe_value *probe_value_create(void);

void probe_value_destroy(probe_value *value);

void probe_value_store(probe_value *value, uint64_t number);

uint64_t probe_value_load(probe_value *value);

#endif
