#ifndef CONDUIT_PLUGIN_C_API_H
#define CONDUIT_PLUGIN_C_API_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define CONDUIT_PLUGIN_EXPORT __declspec(dllexport)
#define CONDUIT_PLUGIN_CALL __cdecl
#else
#define CONDUIT_PLUGIN_EXPORT __attribute__((visibility("default")))
#define CONDUIT_PLUGIN_CALL
#endif

#define CONDUIT_PLUGIN_ABI_MAJOR 1u
#define CONDUIT_PLUGIN_ABI_MINOR 0u
#define CONDUIT_PLUGIN_DESCRIPTOR_VERSION 1u
#define CONDUIT_PLUGIN_FEATURE_EVENTS (1ull << 0)
#define CONDUIT_PLUGIN_FEATURE_WORLD (1ull << 1)
#define CONDUIT_PLUGIN_FEATURE_LOGGING (1ull << 2)
#define CONDUIT_PLUGIN_FEATURE_ALLOCATOR (1ull << 3)

typedef struct conduit_string_view {
  const char *data;
  size_t length;
} conduit_string_view;

typedef struct conduit_api_version {
  uint16_t major;
  uint16_t minor;
  uint32_t protocol;
} conduit_api_version;

typedef struct conduit_plugin_metadata {
  uint32_t struct_size;
  conduit_string_view name;
  conduit_string_view version;
  conduit_string_view description;
  conduit_api_version api;
  uint64_t capabilities;
} conduit_plugin_metadata;

typedef struct conduit_plugin_context conduit_plugin_context;
typedef struct conduit_host_api conduit_host_api;

typedef enum conduit_event_id {
  CONDUIT_EVENT_SERVER_START = 0,
  CONDUIT_EVENT_SERVER_SHUTDOWN = 1,
  CONDUIT_EVENT_SERVER_TICK = 2,
  CONDUIT_EVENT_PLAYER_JOIN = 3,
  CONDUIT_EVENT_PLAYER_DISCONNECT = 4,
  CONDUIT_EVENT_PLAYER_CHAT = 5,
  CONDUIT_EVENT_ITEM_USE = 6,
  CONDUIT_EVENT_PLAYER_MOVE = 7,
  CONDUIT_EVENT_DAMAGE = 8,
  CONDUIT_EVENT_BLOCK_PLACE = 9,
  CONDUIT_EVENT_BLOCK_BREAK = 10,
  CONDUIT_EVENT_INVENTORY_OPEN = 11,
  CONDUIT_EVENT_INVENTORY_CLICK = 12,
  CONDUIT_EVENT_INVENTORY_CLOSE = 13,
  CONDUIT_EVENT_TRANSACTION_PREPARE = 14,
  CONDUIT_EVENT_TRANSACTION_COMMIT = 15,
  CONDUIT_EVENT_TRANSACTION_ABORT = 16
} conduit_event_id;

typedef enum conduit_event_phase {
  CONDUIT_EVENT_PHASE_PRE = 0,
  CONDUIT_EVENT_PHASE_COMMIT = 1,
  CONDUIT_EVENT_PHASE_POST = 2
} conduit_event_phase;

typedef enum conduit_event_result {
  CONDUIT_EVENT_CONTINUE = 0,
  CONDUIT_EVENT_CANCEL = 1
} conduit_event_result;

typedef struct conduit_event_view {
  uint32_t event_id;
  uint32_t phase;
  const void *data;
  size_t data_size;
  uint32_t *result;
  uint32_t payload_version;
} conduit_event_view;

typedef struct conduit_server_tick_event {
  uint64_t tick;
} conduit_server_tick_event;

typedef struct conduit_player_event {
  uint64_t handle;
} conduit_player_event;

typedef void(CONDUIT_PLUGIN_CALL *conduit_event_callback_fn)(
    void *userdata, const conduit_event_view *event);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_event_subscribe_fn)(
    void *userdata, uint32_t event_id, uint32_t phase, int16_t priority,
    conduit_event_callback_fn callback, void *callback_userdata,
    uint64_t *subscription);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_event_unsubscribe_fn)(
    void *userdata, uint64_t subscription);

typedef void *(CONDUIT_PLUGIN_CALL *conduit_alloc_fn)(void *userdata,
                                                      size_t size,
                                                      size_t alignment);
typedef void(CONDUIT_PLUGIN_CALL *conduit_free_fn)(void *userdata, void *memory,
                                                   size_t size,
                                                   size_t alignment);
typedef void(CONDUIT_PLUGIN_CALL *conduit_log_fn)(void *userdata,
                                                  uint32_t level,
                                                  conduit_string_view message);
typedef void(CONDUIT_PLUGIN_CALL *conduit_plugin_log_fn)(
    void *userdata, uint32_t plugin_id, conduit_string_view message);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_world_find_fn)(
    void *userdata, conduit_string_view name, uint64_t *handle);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_player_snapshot_fn)(
    void *userdata, uint64_t handle, void *snapshot, size_t snapshot_size);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_world_set_block_fn)(
    void *userdata, uint64_t world, conduit_string_view dimension, int32_t x,
    int32_t y, int32_t z, conduit_string_view block);

typedef struct conduit_allocator {
  void *userdata;
  conduit_alloc_fn alloc;
  conduit_free_fn free;
} conduit_allocator;

struct conduit_host_api {
  uint32_t struct_size;
  conduit_api_version api;
  void *userdata;
  conduit_allocator allocator;
  conduit_log_fn log;
  conduit_world_find_fn world_find;
  conduit_player_snapshot_fn player_snapshot;
  conduit_world_set_block_fn world_set_block;
  conduit_event_subscribe_fn event_subscribe;
  conduit_event_unsubscribe_fn event_unsubscribe;
  uint64_t features;
  conduit_plugin_log_fn log_debug;
  conduit_plugin_log_fn log_info;
  conduit_plugin_log_fn log_warn;
  conduit_plugin_log_fn log_error;
};

struct conduit_plugin_context {
  uint32_t struct_size;
  uint32_t plugin_id;
  const conduit_host_api *host;
};

typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_plugin_on_load_fn)(
    conduit_plugin_context *context);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_plugin_on_start_fn)(
    conduit_plugin_context *context);
typedef void(CONDUIT_PLUGIN_CALL *conduit_plugin_on_shutdown_fn)(
    conduit_plugin_context *context, uint32_t reason);
typedef void(CONDUIT_PLUGIN_CALL *conduit_plugin_on_unload_fn)(
    conduit_plugin_context *context);

typedef struct conduit_plugin_descriptor {
  uint32_t struct_size;
  uint32_t descriptor_version;
  conduit_plugin_metadata metadata;
  conduit_plugin_on_load_fn on_load;
  conduit_plugin_on_start_fn on_start;
  conduit_plugin_on_shutdown_fn on_shutdown;
  conduit_plugin_on_unload_fn on_unload;
} conduit_plugin_descriptor;

typedef const conduit_plugin_descriptor *(
    CONDUIT_PLUGIN_CALL *conduit_plugin_get_descriptor_fn)(
    uint32_t host_abi_major, uint32_t host_abi_minor);

CONDUIT_PLUGIN_EXPORT const conduit_plugin_descriptor *CONDUIT_PLUGIN_CALL
conduit_plugin_get_descriptor(uint32_t host_abi_major, uint32_t host_abi_minor);

#endif
