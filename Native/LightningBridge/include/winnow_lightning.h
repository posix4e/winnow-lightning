#ifndef WINNOW_LIGHTNING_H
#define WINNOW_LIGHTNING_H
#include <stddef.h>
#include <stdint.h>

// ABI 1: UTF-8 JSON control messages; Bitcoin data is consensus-serialized hex.
// All scalar amounts name their unit. Hash strings use Bitcoin display order.
// Calls are synchronous and never call Swift. Handles are serialized in Rust;
// Swift owns connection I/O and Bitcoin chain validation, scanning, and relay.
// Inputs remain caller-owned and must be valid for the call. Every returned
// buffer (including errors) must be freed exactly once via wln_buffer_free.
typedef struct { uint8_t *bytes; size_t length; } WlnBuffer;
int32_t wln_create(const uint8_t *config, size_t config_length,
                   const uint8_t *seed, size_t seed_length, WlnBuffer *output);
int32_t wln_call(uint64_t handle, const uint8_t *command, size_t command_length, WlnBuffer *output);
void wln_destroy(uint64_t handle);
void wln_buffer_free(WlnBuffer buffer);
#endif
