#define _POSIX_C_SOURCE 200809L
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    atomic_int calls;
    atomic_int active;
    atomic_int max_active;
    atomic_int blocked;
    atomic_int released;
    atomic_int retired;
    atomic_int after_retirement;
} fixture_handle;

void *fixture_create(void) { return calloc(1, sizeof(fixture_handle)); }
void fixture_release(void *pointer) {
    atomic_store(&((fixture_handle *)pointer)->released, 1);
}
int fixture_blocked(void *pointer) {
    return atomic_load(&((fixture_handle *)pointer)->blocked);
}
int fixture_calls(void *pointer) {
    return atomic_load(&((fixture_handle *)pointer)->calls);
}
int fixture_max_active(void *pointer) {
    return atomic_load(&((fixture_handle *)pointer)->max_active);
}
void fixture_retire(void *pointer) {
    atomic_store(&((fixture_handle *)pointer)->retired, 1);
}
int fixture_after_retirement(void *pointer) {
    return atomic_load(&((fixture_handle *)pointer)->after_retirement);
}
void fixture_destroy(void *pointer) { free(pointer); }
uint64_t fixture_thread(void) { return (uint64_t)(uintptr_t)pthread_self(); }

char *mpv_get_property_string(void *pointer, const char *name) {
    fixture_handle *handle = pointer;
    if (atomic_load(&handle->retired))
        atomic_fetch_add(&handle->after_retirement, 1);
    int active = atomic_fetch_add(&handle->active, 1) + 1;
    int previous = atomic_load(&handle->max_active);
    while (previous < active &&
           !atomic_compare_exchange_weak(&handle->max_active, &previous, active)) {}
    int call = atomic_fetch_add(&handle->calls, 1) + 1;
    if (!strcmp(name, "gate")) {
        atomic_store(&handle->blocked, 1);
        const struct timespec delay = { .tv_sec = 0, .tv_nsec = 1000000 };
        // A failed Dart assertion cannot leave a native call stuck forever.
        for (int i = 0; i < 5000 && !atomic_load(&handle->released); i++)
            nanosleep(&delay, NULL);
    }
    char value[80];
    if (!strcmp(name, "thread"))
        snprintf(value, sizeof(value), "%llu", (unsigned long long)fixture_thread());
    else
        snprintf(value, sizeof(value), "%d:%s", call, name);
    atomic_fetch_sub(&handle->active, 1);
    return !strcmp(name, "missing") ? NULL : strdup(value);
}

void mpv_free(void *pointer) { free(pointer); }
