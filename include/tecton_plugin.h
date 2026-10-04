#ifndef TECTON_PLUGIN_C_API_H
#define TECTON_PLUGIN_C_API_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define TECTON_PLUGIN_EXPORT __declspec(dllexport)
#define TECTON_PLUGIN_CALL __cdecl
#else
#define TECTON_PLUGIN_EXPORT __attribute__((visibility("default")))
#define TECTON_PLUGIN_CALL
#endif

#define TECTON_PLUGIN_ABI_MAJOR 1u
#define TECTON_PLUGIN_ABI_MINOR 4u
#define TECTON_PLUGIN_DESCRIPTOR_QUERY_MINOR 0u
#define TECTON_PLUGIN_DESCRIPTOR_VERSION 1u
#define TECTON_PLUGIN_FEATURE_EVENTS (1ull << 0)
#define TECTON_PLUGIN_FEATURE_WORLD (1ull << 1)
#define TECTON_PLUGIN_FEATURE_LOGGING (1ull << 2)
#define TECTON_PLUGIN_FEATURE_ALLOCATOR (1ull << 3)
#define TECTON_PLUGIN_FEATURE_INTERFACES (1ull << 4)
#define TECTON_PLUGIN_FEATURE_CORE (1ull << 5)
#define TECTON_PLUGIN_FEATURE_SCHEDULER (1ull << 6)
#define TECTON_PLUGIN_FEATURE_PLAYERS (1ull << 7)
#define TECTON_PLUGIN_FEATURE_ENTITIES (1ull << 8)
#define TECTON_PLUGIN_FEATURE_ITEMS (1ull << 9)
#define TECTON_PLUGIN_FEATURE_BLOCKS (1ull << 10)
#define TECTON_PLUGIN_FEATURE_INVENTORIES (1ull << 11)
#define TECTON_PLUGIN_FEATURE_NETWORK (1ull << 12)
#define TECTON_INTERFACE_CORE 1u
#define TECTON_INTERFACE_LOGGING 2u
#define TECTON_INTERFACE_EVENTS 3u
#define TECTON_INTERFACE_SCHEDULER 4u
#define TECTON_INTERFACE_WORLD 5u
#define TECTON_INTERFACE_PLAYERS 6u
#define TECTON_INTERFACE_ENTITIES 7u
#define TECTON_INTERFACE_ITEMS 8u
#define TECTON_INTERFACE_BLOCKS 9u
#define TECTON_INTERFACE_INVENTORIES 10u
#define TECTON_INTERFACE_REGISTRIES 11u
#define TECTON_INTERFACE_NETWORK 12u

#define TECTON_EVENT_FLAG_CANCELABLE (1u << 0)
#define TECTON_EVENT_FLAG_MUTABLE (1u << 1)
#define TECTON_EVENT_FLAG_CALLBACK_ONLY (1u << 2)

#define TECTON_RESULT_OK 0
#define TECTON_RESULT_INVALID_ARGUMENT (-1)
#define TECTON_RESULT_UNSUPPORTED (-2)
#define TECTON_RESULT_NOT_FOUND (-3)
#define TECTON_RESULT_WRONG_THREAD (-4)
#define TECTON_RESULT_INVALID_HANDLE (-5)
#define TECTON_RESULT_BUSY (-6)
#define TECTON_RESULT_CONFLICT (-7)
#define TECTON_RESULT_OUT_OF_MEMORY (-8)

#define TECTON_PACKET_PRIORITY_NORMAL 0u
#define TECTON_PACKET_PRIORITY_IMMEDIATE 1u
#define TECTON_EVENT_CUSTOM_BASE 0x1000u

#define TECTON_STRUCT_HAS_FIELD(value, type, field) \
  ((value) != NULL &&                                                       \
   (value)->struct_size >=                                                    \
       (uint32_t)(offsetof(type, field) + sizeof(((type *)0)->field)))

typedef struct tecton_string_view {
  const char *data;
  size_t length;
} tecton_string_view;

typedef struct tecton_api_version {
  uint16_t major;
  uint16_t minor;
  uint32_t protocol;
} tecton_api_version;

typedef struct tecton_plugin_metadata {
  uint32_t struct_size;
  tecton_string_view name;
  tecton_string_view version;
  tecton_string_view description;
  tecton_api_version api;
  uint64_t capabilities;
} tecton_plugin_metadata;

typedef struct tecton_plugin_context tecton_plugin_context;
typedef struct tecton_host_api tecton_host_api;

typedef enum tecton_event_id {
  TECTON_EVENT_SERVER_START = 0,
  TECTON_EVENT_SERVER_SHUTDOWN = 1,
  TECTON_EVENT_SERVER_TICK = 2,
  TECTON_EVENT_PLAYER_JOIN = 3,
  TECTON_EVENT_PLAYER_DISCONNECT = 4,
  TECTON_EVENT_PLAYER_CHAT = 5,
  TECTON_EVENT_ITEM_USE = 6,
  TECTON_EVENT_PLAYER_MOVE = 7,
  TECTON_EVENT_DAMAGE = 8,
  TECTON_EVENT_BLOCK_PLACE = 9,
  TECTON_EVENT_BLOCK_BREAK = 10,
  TECTON_EVENT_INVENTORY_OPEN = 11,
  TECTON_EVENT_INVENTORY_CLICK = 12,
  TECTON_EVENT_INVENTORY_CLOSE = 13,
  TECTON_EVENT_TRANSACTION_PREPARE = 14,
  TECTON_EVENT_TRANSACTION_COMMIT = 15,
  TECTON_EVENT_TRANSACTION_ABORT = 16
} tecton_event_id;

typedef enum tecton_event_phase {
  TECTON_EVENT_PHASE_PRE = 0,
  TECTON_EVENT_PHASE_COMMIT = 1,
  TECTON_EVENT_PHASE_POST = 2
} tecton_event_phase;

typedef enum tecton_event_result {
  TECTON_EVENT_CONTINUE = 0,
  TECTON_EVENT_CANCEL = 1
} tecton_event_result;

typedef struct tecton_event_view {
  uint32_t event_id;
  uint32_t phase;
  const void *data;
  size_t data_size;
  uint32_t *result;
  uint32_t payload_version;
  uint32_t struct_size;
  uint32_t flags;
  uint32_t payload_schema;
} tecton_event_view;

#define TECTON_EVENT_SCHEMA_SERVER_TICK_V1 0x10001u
#define TECTON_EVENT_SCHEMA_PLAYER_V1 0x10002u

typedef struct tecton_server_tick_event {
  uint64_t tick;
} tecton_server_tick_event;

typedef struct tecton_player_event {
  uint64_t handle;
} tecton_player_event;

typedef void(TECTON_PLUGIN_CALL *tecton_event_callback_fn)(
    void *userdata, const tecton_event_view *event);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_event_subscribe_fn)(
    void *userdata, uint32_t event_id, uint32_t phase, int16_t priority,
    tecton_event_callback_fn callback, void *callback_userdata,
    uint64_t *subscription);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_event_unsubscribe_fn)(
    void *userdata, uint64_t subscription);

typedef void *(TECTON_PLUGIN_CALL *tecton_alloc_fn)(void *userdata,
                                                      size_t size,
                                                      size_t alignment);
typedef void(TECTON_PLUGIN_CALL *tecton_free_fn)(void *userdata, void *memory,
                                                   size_t size,
                                                   size_t alignment);
typedef void(TECTON_PLUGIN_CALL *tecton_log_fn)(void *userdata,
                                                  uint32_t level,
                                                  tecton_string_view message);
typedef void(TECTON_PLUGIN_CALL *tecton_plugin_log_fn)(
    void *userdata, uint32_t plugin_id, tecton_string_view message);
typedef struct tecton_interface_header {
  uint32_t struct_size;
  uint16_t major;
  uint16_t minor;
  uint32_t interface_id;
  uint64_t features;
} tecton_interface_header;
typedef int32_t(TECTON_PLUGIN_CALL *tecton_get_interface_fn)(
    void *userdata, uint32_t interface_id, uint16_t major, uint16_t minor,
    const tecton_interface_header **interface);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_find_fn)(
    void *userdata, tecton_string_view name, uint64_t *handle);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_player_snapshot_fn)(
    void *userdata, uint64_t handle, void *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_set_block_fn)(
    void *userdata, uint64_t world, tecton_string_view dimension, int32_t x,
    int32_t y, int32_t z, tecton_string_view block);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_core_get_tick_fn)(
    void *userdata, uint64_t *tick);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_core_get_state_fn)(
    void *userdata, uint32_t *state);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_scheduler_callback_fn)(
    void *userdata);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_scheduler_schedule_fn)(
    void *userdata, uint32_t owner_id, tecton_scheduler_callback_fn callback,
    void *callback_userdata, uint64_t *task);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_scheduler_cancel_fn)(
    void *userdata, uint64_t task);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_scheduler_cancel_owner_fn)(
    void *userdata, uint32_t owner_id);

typedef struct tecton_snapshot_header {
  uint32_t struct_size;
  uint16_t version;
  uint16_t reserved;
} tecton_snapshot_header;

typedef struct tecton_world_snapshot {
  tecton_snapshot_header header;
  uint64_t handle;
  tecton_string_view name;
} tecton_world_snapshot;

typedef struct tecton_player_snapshot {
  tecton_snapshot_header header;
  uint64_t handle;
  int64_t runtime_id;
  tecton_string_view name;
  tecton_string_view uuid;
  uint64_t world;
  tecton_string_view dimension;
  float x;
  float y;
  float z;
} tecton_player_snapshot;

typedef struct tecton_entity_snapshot {
  tecton_snapshot_header header;
  uint64_t handle;
  int64_t runtime_id;
  tecton_string_view type;
  uint64_t world;
  tecton_string_view dimension;
  float x;
  float y;
  float z;
} tecton_entity_snapshot;

typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_find_interface_fn)(
    void *userdata, tecton_string_view name, uint64_t *handle);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_get_snapshot_fn)(
    void *userdata, uint64_t handle, tecton_world_snapshot *snapshot,
    size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_players_count_fn)(
    void *userdata, size_t *count);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_players_get_snapshot_fn)(
    void *userdata, size_t index, tecton_player_snapshot *snapshot,
    size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_entities_count_fn)(
    void *userdata, uint64_t world, tecton_string_view dimension, size_t *count);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_entities_get_snapshot_fn)(
    void *userdata, uint64_t world, tecton_string_view dimension, size_t index,
    tecton_entity_snapshot *snapshot, size_t snapshot_size);

typedef struct tecton_world_api {
  tecton_interface_header header;
  tecton_world_find_interface_fn find;
  tecton_world_get_snapshot_fn get_snapshot;
} tecton_world_api;

typedef struct tecton_players_api {
  tecton_interface_header header;
  tecton_players_count_fn count;
  tecton_players_get_snapshot_fn get_snapshot;
} tecton_players_api;

typedef struct tecton_entities_api {
  tecton_interface_header header;
  tecton_entities_count_fn count;
  tecton_entities_get_snapshot_fn get_snapshot;
} tecton_entities_api;

typedef struct tecton_item_snapshot {
  tecton_snapshot_header header;
  uint64_t handle;
  int32_t network_id;
  uint16_t max_stack_size;
  uint8_t stackable;
  uint8_t reserved[5];
  tecton_string_view identifier;
} tecton_item_snapshot;

typedef struct tecton_block_snapshot {
  tecton_snapshot_header header;
  uint64_t world;
  tecton_string_view dimension;
  int32_t x;
  int32_t y;
  int32_t z;
  int32_t network_id;
  tecton_string_view identifier;
} tecton_block_snapshot;

typedef struct tecton_inventory_item_snapshot {
  tecton_snapshot_header header;
  uint8_t present;
  uint8_t reserved[3];
  uint16_t count;
  uint16_t reserved_count;
  int32_t network_id;
  uint32_t metadata;
  tecton_string_view identifier;
} tecton_inventory_item_snapshot;

typedef int32_t(TECTON_PLUGIN_CALL *tecton_items_count_fn)(void *userdata, size_t *count);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_items_get_snapshot_fn)(void *userdata, size_t index, tecton_item_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_blocks_get_snapshot_fn)(void *userdata, uint64_t world, tecton_string_view dimension, int32_t x, int32_t y, int32_t z, tecton_block_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_inventory_get_size_fn)(void *userdata, uint64_t player, uint32_t *size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_inventory_get_item_fn)(void *userdata, uint64_t player, uint32_t slot, tecton_inventory_item_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_network_send_fn)(void *userdata, uint64_t player, tecton_string_view packet, uint32_t priority);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_network_broadcast_fn)(void *userdata, tecton_string_view packet, uint32_t priority);

typedef struct tecton_items_api {
  tecton_interface_header header;
  tecton_items_count_fn count;
  tecton_items_get_snapshot_fn get_snapshot;
} tecton_items_api;

typedef struct tecton_blocks_api {
  tecton_interface_header header;
  tecton_blocks_get_snapshot_fn get_snapshot;
} tecton_blocks_api;

typedef struct tecton_inventories_api {
  tecton_interface_header header;
  tecton_inventory_get_size_fn get_size;
  tecton_inventory_get_item_fn get_item;
} tecton_inventories_api;

typedef struct tecton_core_api {
  tecton_interface_header header;
  tecton_core_get_tick_fn get_tick;
  tecton_core_get_state_fn get_state;
} tecton_core_api;

typedef struct tecton_scheduler_api {
  tecton_interface_header header;
  tecton_scheduler_schedule_fn schedule;
  tecton_scheduler_cancel_fn cancel;
  tecton_scheduler_cancel_owner_fn cancel_owner;
} tecton_scheduler_api;

typedef struct tecton_network_api {
  tecton_interface_header header;
  tecton_network_send_fn send;
  tecton_network_broadcast_fn broadcast;
} tecton_network_api;

typedef struct tecton_allocator {
  void *userdata;
  tecton_alloc_fn alloc;
  tecton_free_fn free;
} tecton_allocator;

struct tecton_host_api {
  uint32_t struct_size;
  tecton_api_version api;
  void *userdata;
  tecton_allocator allocator;
  tecton_log_fn log;
  tecton_world_find_fn world_find;
  tecton_player_snapshot_fn player_snapshot;
  tecton_world_set_block_fn world_set_block;
  tecton_event_subscribe_fn event_subscribe;
  tecton_event_unsubscribe_fn event_unsubscribe;
  uint64_t features;
  tecton_plugin_log_fn log_debug;
  tecton_plugin_log_fn log_info;
  tecton_plugin_log_fn log_warn;
  tecton_plugin_log_fn log_error;
  tecton_get_interface_fn get_interface;
};

#define TECTON_SERVER_STATE_STARTING 0u
#define TECTON_SERVER_STATE_RUNNING 1u
#define TECTON_SERVER_STATE_STOPPING 2u
#define TECTON_SERVER_STATE_STOPPED 3u

struct tecton_plugin_context {
  uint32_t struct_size;
  uint32_t plugin_id;
  const tecton_host_api *host;
};

typedef int32_t(TECTON_PLUGIN_CALL *tecton_plugin_on_load_fn)(
    tecton_plugin_context *context);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_plugin_on_start_fn)(
    tecton_plugin_context *context);
typedef void(TECTON_PLUGIN_CALL *tecton_plugin_on_shutdown_fn)(
    tecton_plugin_context *context, uint32_t reason);
typedef void(TECTON_PLUGIN_CALL *tecton_plugin_on_unload_fn)(
    tecton_plugin_context *context);

typedef struct tecton_plugin_descriptor {
  uint32_t struct_size;
  uint32_t descriptor_version;
  tecton_plugin_metadata metadata;
  tecton_plugin_on_load_fn on_load;
  tecton_plugin_on_start_fn on_start;
  tecton_plugin_on_shutdown_fn on_shutdown;
  tecton_plugin_on_unload_fn on_unload;
} tecton_plugin_descriptor;

typedef const tecton_plugin_descriptor *(
    TECTON_PLUGIN_CALL *tecton_plugin_get_descriptor_fn)(
    uint32_t host_abi_major, uint32_t host_abi_minor);

TECTON_PLUGIN_EXPORT const tecton_plugin_descriptor *TECTON_PLUGIN_CALL
tecton_plugin_get_descriptor(uint32_t host_abi_major, uint32_t host_abi_minor);

#endif
