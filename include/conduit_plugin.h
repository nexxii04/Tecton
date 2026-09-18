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
#define CONDUIT_PLUGIN_ABI_MINOR 3u
#define CONDUIT_PLUGIN_DESCRIPTOR_QUERY_MINOR 0u
#define CONDUIT_PLUGIN_DESCRIPTOR_VERSION 1u
#define CONDUIT_PLUGIN_FEATURE_EVENTS (1ull << 0)
#define CONDUIT_PLUGIN_FEATURE_WORLD (1ull << 1)
#define CONDUIT_PLUGIN_FEATURE_LOGGING (1ull << 2)
#define CONDUIT_PLUGIN_FEATURE_ALLOCATOR (1ull << 3)
#define CONDUIT_PLUGIN_FEATURE_INTERFACES (1ull << 4)
#define CONDUIT_PLUGIN_FEATURE_CORE (1ull << 5)
#define CONDUIT_PLUGIN_FEATURE_SCHEDULER (1ull << 6)
#define CONDUIT_PLUGIN_FEATURE_PLAYERS (1ull << 7)
#define CONDUIT_PLUGIN_FEATURE_ENTITIES (1ull << 8)
#define CONDUIT_PLUGIN_FEATURE_ITEMS (1ull << 9)
#define CONDUIT_PLUGIN_FEATURE_BLOCKS (1ull << 10)
#define CONDUIT_PLUGIN_FEATURE_INVENTORIES (1ull << 11)
#define CONDUIT_INTERFACE_CORE 1u
#define CONDUIT_INTERFACE_LOGGING 2u
#define CONDUIT_INTERFACE_EVENTS 3u
#define CONDUIT_INTERFACE_SCHEDULER 4u
#define CONDUIT_INTERFACE_WORLD 5u
#define CONDUIT_INTERFACE_PLAYERS 6u
#define CONDUIT_INTERFACE_ENTITIES 7u
#define CONDUIT_INTERFACE_ITEMS 8u
#define CONDUIT_INTERFACE_BLOCKS 9u
#define CONDUIT_INTERFACE_INVENTORIES 10u
#define CONDUIT_INTERFACE_REGISTRIES 11u

#define CONDUIT_EVENT_FLAG_CANCELABLE (1u << 0)
#define CONDUIT_EVENT_FLAG_MUTABLE (1u << 1)
#define CONDUIT_EVENT_FLAG_CALLBACK_ONLY (1u << 2)

#define CONDUIT_RESULT_OK 0
#define CONDUIT_RESULT_INVALID_ARGUMENT (-1)
#define CONDUIT_RESULT_UNSUPPORTED (-2)
#define CONDUIT_RESULT_NOT_FOUND (-3)
#define CONDUIT_RESULT_WRONG_THREAD (-4)
#define CONDUIT_RESULT_INVALID_HANDLE (-5)
#define CONDUIT_RESULT_BUSY (-6)
#define CONDUIT_RESULT_CONFLICT (-7)
#define CONDUIT_RESULT_OUT_OF_MEMORY (-8)
#define CONDUIT_EVENT_CUSTOM_BASE 0x1000u

#define CONDUIT_STRUCT_HAS_FIELD(value, type, field) \
  ((value) != NULL &&                                                       \
   (value)->struct_size >=                                                    \
       (uint32_t)(offsetof(type, field) + sizeof(((type *)0)->field)))

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
  uint32_t struct_size;
  uint32_t flags;
  uint32_t payload_schema;
} conduit_event_view;

#define CONDUIT_EVENT_SCHEMA_SERVER_TICK_V1 0x10001u
#define CONDUIT_EVENT_SCHEMA_PLAYER_V1 0x10002u

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
typedef struct conduit_interface_header {
  uint32_t struct_size;
  uint16_t major;
  uint16_t minor;
  uint32_t interface_id;
  uint64_t features;
} conduit_interface_header;
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_get_interface_fn)(
    void *userdata, uint32_t interface_id, uint16_t major, uint16_t minor,
    const conduit_interface_header **interface);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_world_find_fn)(
    void *userdata, conduit_string_view name, uint64_t *handle);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_player_snapshot_fn)(
    void *userdata, uint64_t handle, void *snapshot, size_t snapshot_size);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_world_set_block_fn)(
    void *userdata, uint64_t world, conduit_string_view dimension, int32_t x,
    int32_t y, int32_t z, conduit_string_view block);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_core_get_tick_fn)(
    void *userdata, uint64_t *tick);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_core_get_state_fn)(
    void *userdata, uint32_t *state);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_scheduler_callback_fn)(
    void *userdata);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_scheduler_schedule_fn)(
    void *userdata, uint32_t owner_id, conduit_scheduler_callback_fn callback,
    void *callback_userdata, uint64_t *task);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_scheduler_cancel_fn)(
    void *userdata, uint64_t task);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_scheduler_cancel_owner_fn)(
    void *userdata, uint32_t owner_id);

typedef struct conduit_snapshot_header {
  uint32_t struct_size;
  uint16_t version;
  uint16_t reserved;
} conduit_snapshot_header;

typedef struct conduit_world_snapshot {
  conduit_snapshot_header header;
  uint64_t handle;
  conduit_string_view name;
} conduit_world_snapshot;

typedef struct conduit_player_snapshot {
  conduit_snapshot_header header;
  uint64_t handle;
  int64_t runtime_id;
  conduit_string_view name;
  conduit_string_view uuid;
  uint64_t world;
  conduit_string_view dimension;
  float x;
  float y;
  float z;
} conduit_player_snapshot;

typedef struct conduit_entity_snapshot {
  conduit_snapshot_header header;
  uint64_t handle;
  int64_t runtime_id;
  conduit_string_view type;
  uint64_t world;
  conduit_string_view dimension;
  float x;
  float y;
  float z;
} conduit_entity_snapshot;

typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_world_find_interface_fn)(
    void *userdata, conduit_string_view name, uint64_t *handle);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_world_get_snapshot_fn)(
    void *userdata, uint64_t handle, conduit_world_snapshot *snapshot,
    size_t snapshot_size);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_players_count_fn)(
    void *userdata, size_t *count);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_players_get_snapshot_fn)(
    void *userdata, size_t index, conduit_player_snapshot *snapshot,
    size_t snapshot_size);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_entities_count_fn)(
    void *userdata, uint64_t world, conduit_string_view dimension, size_t *count);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_entities_get_snapshot_fn)(
    void *userdata, uint64_t world, conduit_string_view dimension, size_t index,
    conduit_entity_snapshot *snapshot, size_t snapshot_size);

typedef struct conduit_world_api {
  conduit_interface_header header;
  conduit_world_find_interface_fn find;
  conduit_world_get_snapshot_fn get_snapshot;
} conduit_world_api;

typedef struct conduit_players_api {
  conduit_interface_header header;
  conduit_players_count_fn count;
  conduit_players_get_snapshot_fn get_snapshot;
} conduit_players_api;

typedef struct conduit_entities_api {
  conduit_interface_header header;
  conduit_entities_count_fn count;
  conduit_entities_get_snapshot_fn get_snapshot;
} conduit_entities_api;

typedef struct conduit_item_snapshot {
  conduit_snapshot_header header;
  uint64_t handle;
  int32_t network_id;
  uint16_t max_stack_size;
  uint8_t stackable;
  uint8_t reserved[5];
  conduit_string_view identifier;
} conduit_item_snapshot;

typedef struct conduit_block_snapshot {
  conduit_snapshot_header header;
  uint64_t world;
  conduit_string_view dimension;
  int32_t x;
  int32_t y;
  int32_t z;
  int32_t network_id;
  conduit_string_view identifier;
} conduit_block_snapshot;

typedef struct conduit_inventory_item_snapshot {
  conduit_snapshot_header header;
  uint8_t present;
  uint8_t reserved[3];
  uint16_t count;
  uint16_t reserved_count;
  int32_t network_id;
  uint32_t metadata;
  conduit_string_view identifier;
} conduit_inventory_item_snapshot;

typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_items_count_fn)(void *userdata, size_t *count);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_items_get_snapshot_fn)(void *userdata, size_t index, conduit_item_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_blocks_get_snapshot_fn)(void *userdata, uint64_t world, conduit_string_view dimension, int32_t x, int32_t y, int32_t z, conduit_block_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_inventory_get_size_fn)(void *userdata, uint64_t player, uint32_t *size);
typedef int32_t(CONDUIT_PLUGIN_CALL *conduit_inventory_get_item_fn)(void *userdata, uint64_t player, uint32_t slot, conduit_inventory_item_snapshot *snapshot, size_t snapshot_size);

typedef struct conduit_items_api {
  conduit_interface_header header;
  conduit_items_count_fn count;
  conduit_items_get_snapshot_fn get_snapshot;
} conduit_items_api;

typedef struct conduit_blocks_api {
  conduit_interface_header header;
  conduit_blocks_get_snapshot_fn get_snapshot;
} conduit_blocks_api;

typedef struct conduit_inventories_api {
  conduit_interface_header header;
  conduit_inventory_get_size_fn get_size;
  conduit_inventory_get_item_fn get_item;
} conduit_inventories_api;

typedef struct conduit_core_api {
  conduit_interface_header header;
  conduit_core_get_tick_fn get_tick;
  conduit_core_get_state_fn get_state;
} conduit_core_api;

typedef struct conduit_scheduler_api {
  conduit_interface_header header;
  conduit_scheduler_schedule_fn schedule;
  conduit_scheduler_cancel_fn cancel;
  conduit_scheduler_cancel_owner_fn cancel_owner;
} conduit_scheduler_api;

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
  conduit_get_interface_fn get_interface;
};

#define CONDUIT_SERVER_STATE_STARTING 0u
#define CONDUIT_SERVER_STATE_RUNNING 1u
#define CONDUIT_SERVER_STATE_STOPPING 2u
#define CONDUIT_SERVER_STATE_STOPPED 3u

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
