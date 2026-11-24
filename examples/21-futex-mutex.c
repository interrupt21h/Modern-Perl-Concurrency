/*
 * Three-state futex mutex (U. Drepper, "Futexes Are Tricky", mutex 3),
 * written with C11 atomics. This is what sits underneath pthread mutexes
 * and therefore underneath Perl's lock(): a user-space fast path and a
 * kernel slow path that is entered only under contention.
 *
 *   state 0 = unlocked
 *   state 1 = locked, no waiters
 *   state 2 = locked, waiters possible
 *
 * Build and run:  cc -O2 -Wall -Wextra -pthread 21-futex-mutex.c -o futex-mutex
 *                 ./futex-mutex
 * Linux only. For study: production code should use pthread_mutex_t.
 */
#define _GNU_SOURCE
#include <linux/futex.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

#define THREADS    8
#define ITERATIONS 1000000L

typedef struct { _Atomic uint32_t state; } futex_mutex;

static atomic_long slow_path_entries;   /* instrumentation only */

static long futex(futex_mutex *m, int op, uint32_t val)
{
    return syscall(SYS_futex, (uint32_t *)&m->state, op, val, NULL, NULL, 0);
}

/* Compare-and-exchange returning the value observed before the attempt. */
static uint32_t cmpxchg(futex_mutex *m, uint32_t expected, uint32_t desired)
{
    atomic_compare_exchange_strong_explicit(&m->state, &expected, desired,
        memory_order_acquire, memory_order_relaxed);
    return expected;
}

static void mutex_lock(futex_mutex *m)
{
    uint32_t c = cmpxchg(m, 0, 1);          /* fast path: 0 -> 1, no syscall */
    if (c == 0)
        return;
    atomic_fetch_add_explicit(&slow_path_entries, 1, memory_order_relaxed);
    /* Announce a waiter by forcing the state to 2 before sleeping. */
    if (c != 2)
        c = atomic_exchange_explicit(&m->state, 2, memory_order_acquire);
    while (c != 0) {
        /* The kernel re-checks state == 2 atomically before sleeping, so an
         * unlock between our exchange and this call cannot be lost. EINTR
         * and EAGAIN are harmless: the loop simply tries again. */
        futex(m, FUTEX_WAIT_PRIVATE, 2);
        c = atomic_exchange_explicit(&m->state, 2, memory_order_acquire);
    }
}

static void mutex_unlock(futex_mutex *m)
{
    /* 1 -> 0 means nobody can be waiting: no syscall. 2 -> 1 means someone
     * may be asleep: finish the release and wake exactly one waiter. */
    if (atomic_fetch_sub_explicit(&m->state, 1, memory_order_release) != 1) {
        atomic_store_explicit(&m->state, 0, memory_order_release);
        futex(m, FUTEX_WAKE_PRIVATE, 1);
    }
}

static futex_mutex lock = { 0 };
static long counter;                    /* deliberately NOT atomic */

static void *worker(void *arg)
{
    (void)arg;
    for (long i = 0; i < ITERATIONS; i++) {
        mutex_lock(&lock);
        counter++;                      /* plain read-modify-write */
        mutex_unlock(&lock);
    }
    return NULL;
}

int main(void)
{
    pthread_t t[THREADS];
    for (int i = 0; i < THREADS; i++)
        if (pthread_create(&t[i], NULL, worker, NULL) != 0)
            return perror("pthread_create"), 1;
    for (int i = 0; i < THREADS; i++)
        pthread_join(t[i], NULL);

    long expected = THREADS * ITERATIONS;
    long slow = atomic_load(&slow_path_entries);
    printf("counter=%ld expected=%ld slow-path=%.2f%%\n",
        counter, expected, 100.0 * slow / expected);
    return counter == expected ? 0 : 1;
}
