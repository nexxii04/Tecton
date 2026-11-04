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

#if defined(__cplusplus)
#define TECTON_STATIC_ASSERT(condition, message) static_assert(condition, message)
#define TECTON_STR(literal) tecton_string_view{(literal), sizeof(literal) - 1}
#else
#define TECTON_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#define TECTON_STR(literal) ((tecton_string_view){(literal), sizeof(literal) - 1})
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define TECTON_PLUGIN_ABI_MAJOR 2u
#define TECTON_PLUGIN_ABI_MINOR 0u
#define TECTON_PLUGIN_DESCRIPTOR_VERSION 2u

#define TECTON_PLUGIN_STATUS_OK 0u
#define TECTON_PLUGIN_STATUS_ABI_MAJOR 1u
#define TECTON_PLUGIN_STATUS_ABI_MINOR 2u
#define TECTON_PLUGIN_STATUS_HOST_TOO_OLD 3u
#define TECTON_PLUGIN_STATUS_BUILD_TARGET 4u

#define TECTON_LOG_TRACE 0u
#define TECTON_LOG_DEBUG 1u
#define TECTON_LOG_INFO 2u
#define TECTON_LOG_WARN 3u
#define TECTON_LOG_ERROR 4u

#define TECTON_SHUTDOWN_NORMAL 0u
#define TECTON_SHUTDOWN_FAULT 1u
#define TECTON_SHUTDOWN_RELOAD 2u
#define TECTON_SHUTDOWN_SERVER_EXIT 3u

#define TECTON_EVENT_PHASE_PRE 0u
#define TECTON_EVENT_PHASE_COMMIT 1u
#define TECTON_EVENT_PHASE_POST 2u

#define TECTON_FEATURE_EVENTS (UINT64_C(1) << 0)
#define TECTON_FEATURE_LOGGING (UINT64_C(1) << 1)
#define TECTON_FEATURE_ALLOCATOR (UINT64_C(1) << 2)
#define TECTON_FEATURE_SCHEDULER (UINT64_C(1) << 3)
#define TECTON_FEATURE_WORLD (UINT64_C(1) << 4)
#define TECTON_FEATURE_PLAYERS (UINT64_C(1) << 5)
#define TECTON_FEATURE_ENTITIES (UINT64_C(1) << 6)
#define TECTON_FEATURE_ITEMS (UINT64_C(1) << 7)
#define TECTON_FEATURE_BLOCKS (UINT64_C(1) << 8)
#define TECTON_FEATURE_INVENTORIES (UINT64_C(1) << 9)
#define TECTON_FEATURE_REGISTRIES (UINT64_C(1) << 10)
#define TECTON_FEATURE_NETWORK (UINT64_C(1) << 11)
#define TECTON_FEATURE_COMMANDS (UINT64_C(1) << 12)
#define TECTON_FEATURE_CUSTOM_EVENTS (UINT64_C(1) << 13)
#define TECTON_FEATURE_TRAITS (UINT64_C(1) << 14)
#define TECTON_FEATURE_HOT_UNLOAD (UINT64_C(1) << 15)

#define TECTON_BLOCK_APPLY_TRAITS (UINT32_C(1) << 0)
#define TECTON_BLOCK_UPDATE_CLIENTS (UINT32_C(1) << 1)
#define TECTON_BLOCK_SILENT (UINT32_C(1) << 2)

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
#define TECTON_INTERFACE_COMMANDS 13u

#define TECTON_MAX_CUSTOM_EVENTS 128u
#define TECTON_CUSTOM_PAYLOAD_MAX 56u

#define TECTON_EVENT_FLAG_CANCELABLE (UINT16_C(1) << 0)
#define TECTON_EVENT_FLAG_MUTABLE (UINT16_C(1) << 1) /* honored in pre only; ignored in commit and post */
#define TECTON_EVENT_FLAG_CALLBACK_ONLY (UINT16_C(1) << 2)
#define TECTON_EVENT_FLAG_BORROWED (UINT16_C(1) << 3)

#define TECTON_RESULT_OK 0
#define TECTON_RESULT_INVALID_ARGUMENT (-1)
#define TECTON_RESULT_UNSUPPORTED (-2)
#define TECTON_RESULT_NOT_FOUND (-3)
#define TECTON_RESULT_WRONG_THREAD (-4)
#define TECTON_RESULT_INVALID_HANDLE (-5)
#define TECTON_RESULT_BUSY (-6)
#define TECTON_RESULT_CONFLICT (-7)
#define TECTON_RESULT_OUT_OF_MEMORY (-8)
#define TECTON_RESULT_VERSION (-9)
#define TECTON_RESULT_UNLOADED (-10)
#define TECTON_RESULT_DENIED (-11)
#define TECTON_RESULT_LIMIT (-12)

#define TECTON_LOAD_REASON_COUNT 14u
typedef enum tecton_load_reason {
  TECTON_LOAD_OK = 0,
  TECTON_LOAD_DLOPEN = 1,
  TECTON_LOAD_SYMBOL_MISSING = 2,
  TECTON_LOAD_LEGACY_ABI = 3,
  TECTON_LOAD_ABI_MAJOR = 4,
  TECTON_LOAD_ABI_MINOR = 5,
  TECTON_LOAD_FINGERPRINT = 6,
  TECTON_LOAD_DESCRIPTOR = 7,
  TECTON_LOAD_METADATA = 8,
  TECTON_LOAD_DUPLICATE_NAME = 9,
  TECTON_LOAD_REQUIRED_FEATURE = 10,
  TECTON_LOAD_MISSING_CALLBACK = 11,
  TECTON_LOAD_CALLBACK_FAILED = 12,
  TECTON_LOAD_OUT_OF_MEMORY = 13
} tecton_load_reason;

#define TECTON_PACKET_PRIORITY_NORMAL 0u
#define TECTON_PACKET_PRIORITY_IMMEDIATE 1u
#define TECTON_EVENT_CUSTOM_BASE 0x1000u

#define TECTON_STRUCT_HAS_FIELD(value, type, field) \
  ((value) != NULL && (value)->struct_size >= (uint32_t)(offsetof(type, field) + sizeof(((type *)0)->field)))

typedef struct tecton_string_view {
  const char *data; /* borrowed for this call; NULL only when length == 0 */
  size_t length;
} tecton_string_view;

typedef struct tecton_api_version {
  uint16_t major;
  uint16_t minor;
  uint16_t patch;
  uint16_t reserved;
} tecton_api_version;

typedef struct tecton_host_query {
  uint32_t struct_size;
  uint32_t abi_major;
  uint32_t abi_minor;
  uint32_t reserved;
  uint64_t abi_fingerprint;
  uint64_t host_features;
  uint32_t tick_rate;
  uint32_t reserved2;
} tecton_host_query;

typedef struct tecton_plugin_descriptor tecton_plugin_descriptor;

typedef struct tecton_plugin_info {
  uint32_t struct_size;
  uint32_t status;
  uint32_t abi_major;
  uint32_t abi_minor;
  uint64_t abi_fingerprint;
  const tecton_plugin_descriptor *descriptor; /* plugin-owned; static; NULL unless status == OK */
  tecton_string_view diagnostic;              /* borrowed; static or plugin lifetime */
  uint64_t reserved;
} tecton_plugin_info;

typedef struct tecton_plugin_metadata {
  uint32_t struct_size;
  uint32_t plugin_flags; /* reserved; must be 0 */
  tecton_string_view name;        /* borrowed; plugin-owned static */
  tecton_string_view version;     /* borrowed; plugin-owned static */
  tecton_string_view description; /* borrowed; plugin-owned static */
  tecton_api_version api;
  uint64_t required_features;
  uint64_t optional_features;
} tecton_plugin_metadata;

typedef struct tecton_plugin_context tecton_plugin_context;
typedef struct tecton_host_api tecton_host_api;

typedef int32_t(TECTON_PLUGIN_CALL *tecton_plugin_on_load_fn)(tecton_plugin_context *context);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_plugin_on_start_fn)(tecton_plugin_context *context);
typedef void(TECTON_PLUGIN_CALL *tecton_plugin_on_shutdown_fn)(tecton_plugin_context *context, uint32_t reason);
typedef void(TECTON_PLUGIN_CALL *tecton_plugin_on_unload_fn)(tecton_plugin_context *context);
typedef void(TECTON_PLUGIN_CALL *tecton_plugin_on_ready_fn)(tecton_plugin_context *context);

typedef struct tecton_plugin_descriptor {
  uint32_t struct_size;
  uint32_t descriptor_version;
  uint64_t abi_fingerprint;
  tecton_plugin_metadata metadata;
  tecton_plugin_on_load_fn on_load;
  tecton_plugin_on_start_fn on_start;
  tecton_plugin_on_shutdown_fn on_shutdown;
  tecton_plugin_on_unload_fn on_unload;
  tecton_plugin_on_ready_fn on_ready; /* optional; NULL allowed */
} tecton_plugin_descriptor;

struct tecton_plugin_context {
  uint32_t struct_size;
  uint32_t plugin_id;
  const tecton_host_api *host; /* host-owned; stable until after on_unload */
  void *engine;                /* host-owned opaque; borrowed */
  uint64_t reserved;
};

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
  TECTON_EVENT_TRANSACTION_ABORT = 16,
  TECTON_EVENT_ENTITY_COMBUST = 17,
  TECTON_EVENT_ENCHANTMENT_APPLY = 18,
  TECTON_EVENT_ENCHANTMENT_REMOVE = 19,
  TECTON_EVENT_ENTITY_SPAWN = 20,
  TECTON_EVENT_ENTITY_DESPAWN = 21,
  TECTON_EVENT_ENTITY_DAMAGE = 22,
  TECTON_EVENT_ENTITY_DEATH = 23,
  TECTON_EVENT_ENTITY_INTERACT = 24
} tecton_event_id;

typedef enum tecton_event_result {
  TECTON_EVENT_CONTINUE = 0,
  TECTON_EVENT_CANCEL = 1
} tecton_event_result;

#define TECTON_SCHEMA(event_id, version) (((uint32_t)(event_id) << 8) | (uint32_t)(version))
#define TECTON_SCHEMA_SERVER_TICK TECTON_SCHEMA(TECTON_EVENT_SERVER_TICK, 1)
#define TECTON_SCHEMA_PLAYER_JOIN TECTON_SCHEMA(TECTON_EVENT_PLAYER_JOIN, 1)
#define TECTON_SCHEMA_PLAYER_DISCONNECT TECTON_SCHEMA(TECTON_EVENT_PLAYER_DISCONNECT, 1)
#define TECTON_SCHEMA_PLAYER_CHAT TECTON_SCHEMA(TECTON_EVENT_PLAYER_CHAT, 1)
#define TECTON_SCHEMA_ITEM_USE TECTON_SCHEMA(TECTON_EVENT_ITEM_USE, 1)
#define TECTON_SCHEMA_PLAYER_MOVE TECTON_SCHEMA(TECTON_EVENT_PLAYER_MOVE, 1)
#define TECTON_SCHEMA_DAMAGE TECTON_SCHEMA(TECTON_EVENT_DAMAGE, 1)
#define TECTON_SCHEMA_BLOCK_PLACE TECTON_SCHEMA(TECTON_EVENT_BLOCK_PLACE, 1)
#define TECTON_SCHEMA_BLOCK_BREAK TECTON_SCHEMA(TECTON_EVENT_BLOCK_BREAK, 1)
#define TECTON_SCHEMA_INVENTORY_OPEN TECTON_SCHEMA(TECTON_EVENT_INVENTORY_OPEN, 1)
#define TECTON_SCHEMA_INVENTORY_CLICK TECTON_SCHEMA(TECTON_EVENT_INVENTORY_CLICK, 1)
#define TECTON_SCHEMA_INVENTORY_CLOSE TECTON_SCHEMA(TECTON_EVENT_INVENTORY_CLOSE, 1)
#define TECTON_SCHEMA_TRANSACTION_PREPARE TECTON_SCHEMA(TECTON_EVENT_TRANSACTION_PREPARE, 1)
#define TECTON_SCHEMA_TRANSACTION_COMMIT TECTON_SCHEMA(TECTON_EVENT_TRANSACTION_COMMIT, 1)
#define TECTON_SCHEMA_TRANSACTION_ABORT TECTON_SCHEMA(TECTON_EVENT_TRANSACTION_ABORT, 1)
#define TECTON_SCHEMA_ENTITY_COMBUST TECTON_SCHEMA(TECTON_EVENT_ENTITY_COMBUST, 1)
#define TECTON_SCHEMA_ENCHANTMENT_APPLY TECTON_SCHEMA(TECTON_EVENT_ENCHANTMENT_APPLY, 1)
#define TECTON_SCHEMA_ENCHANTMENT_REMOVE TECTON_SCHEMA(TECTON_EVENT_ENCHANTMENT_REMOVE, 1)
#define TECTON_SCHEMA_ENTITY_SPAWN TECTON_SCHEMA(TECTON_EVENT_ENTITY_SPAWN, 1)
#define TECTON_SCHEMA_ENTITY_DESPAWN TECTON_SCHEMA(TECTON_EVENT_ENTITY_DESPAWN, 1)
#define TECTON_SCHEMA_ENTITY_DAMAGE TECTON_SCHEMA(TECTON_EVENT_ENTITY_DAMAGE, 1)
#define TECTON_SCHEMA_ENTITY_DEATH TECTON_SCHEMA(TECTON_EVENT_ENTITY_DEATH, 1)
#define TECTON_SCHEMA_ENTITY_INTERACT TECTON_SCHEMA(TECTON_EVENT_ENTITY_INTERACT, 1)
#define TECTON_SCHEMA_PLAYER TECTON_SCHEMA_PLAYER_JOIN

typedef struct tecton_event_view {
  const void *data; /* borrowed for this call; NULL when data_size == 0 */
  size_t data_size;
  int32_t *result; /* host-owned; in/out; never NULL */
  uint32_t schema;
  uint32_t event_id;
  uint16_t phase;
  uint16_t flags;
} tecton_event_view;

typedef struct tecton_server_tick_event {
  uint64_t tick;
} tecton_server_tick_event;

typedef struct tecton_player_event {
  uint64_t handle;
} tecton_player_event;

typedef struct tecton_player_join_event {
  uint64_t handle;
  int64_t runtime_id;
} tecton_player_join_event;

typedef struct tecton_player_ref_event {
  uint64_t handle;
  int64_t runtime_id;
} tecton_player_ref_event;

typedef struct tecton_player_chat_event {
  int64_t runtime_id;
  tecton_string_view message; /* borrowed for this call; mutable in pre */
  uint32_t flags;
  uint32_t reserved;
} tecton_player_chat_event;

typedef struct tecton_item_use_event {
  int64_t runtime_id;
  tecton_string_view identifier; /* borrowed for this call */
  uint32_t flags;
  uint32_t reserved;
} tecton_item_use_event;

typedef struct tecton_player_move_event {
  int64_t runtime_id;
  float from_x;
  float from_y;
  float from_z;
  float to_x;
  float to_y;
  float to_z;
  uint32_t on_ground; /* 0/1 */
  uint32_t reserved;
} tecton_player_move_event;

typedef struct tecton_damage_event {
  int64_t victim_runtime;
  int64_t attacker_runtime;
  float amount;
  uint32_t cause;
  uint32_t reserved;
} tecton_damage_event;

typedef struct tecton_block_place_event {
  int64_t runtime_id;
  int32_t x;
  int32_t y;
  int32_t z;
  int32_t network_id;
  uint32_t reserved;
} tecton_block_place_event;

typedef struct tecton_block_break_event {
  int64_t runtime_id;
  int32_t x;
  int32_t y;
  int32_t z;
  int32_t network_id;
  uint32_t reserved;
} tecton_block_break_event;

typedef struct tecton_inventory_event {
  uint64_t handle;
  uint32_t container_id;
  uint32_t reserved;
} tecton_inventory_event;

typedef struct tecton_inventory_click_event {
  uint64_t handle;
  uint16_t slot;
  uint8_t button;
  uint8_t reserved;
  uint32_t reserved2;
} tecton_inventory_click_event;

typedef struct tecton_transaction_event {
  uint64_t handle;
  uint8_t transaction_id[16];
  uint32_t committed;
  uint32_t reserved;
} tecton_transaction_event;

typedef struct tecton_entity_combust_event {
  int64_t runtime_id;
  int64_t instigator_runtime;
  int32_t duration;
  uint32_t source;
} tecton_entity_combust_event;

typedef struct tecton_enchant_event {
  uint64_t item_handle;
  int64_t actor_runtime;
  uint32_t enchantment_id;
  uint8_t previous_level;
  uint8_t level;
  uint8_t source;
  uint8_t reserved;
} tecton_enchant_event;

typedef struct tecton_entity_spawn_event {
  int64_t runtime_id;
  uint64_t reserved;
} tecton_entity_spawn_event;

typedef struct tecton_entity_despawn_event {
  int64_t runtime_id;
  uint32_t cause;
  uint32_t reserved;
} tecton_entity_despawn_event;

typedef struct tecton_entity_damage_event {
  int64_t target_runtime;
  int64_t source_runtime;
  float amount;
  uint32_t cause;
  uint32_t reserved;
} tecton_entity_damage_event;

typedef struct tecton_entity_death_event {
  int64_t runtime_id;
  int64_t killer_runtime;
  float x;
  float y;
  float z;
  uint32_t reserved;
} tecton_entity_death_event;

typedef struct tecton_entity_interact_event {
  int64_t target_runtime;
  int64_t player_runtime;
  uint32_t action;
  uint32_t reserved;
} tecton_entity_interact_event;

typedef void(TECTON_PLUGIN_CALL *tecton_event_callback_fn)(void *userdata, const tecton_event_view *event);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_event_subscribe_fn)(void *userdata, uint32_t event_id, uint16_t phase, int16_t priority, tecton_event_callback_fn callback, void *callback_userdata, uint64_t *out_subscription);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_event_unsubscribe_fn)(void *userdata, uint64_t subscription);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_emit_custom_fn)(void *userdata, uint32_t schema, const void *payload, size_t payload_size, uint32_t flags);

typedef struct tecton_interface_header {
  uint32_t struct_size;
  uint16_t major;
  uint16_t minor;
  uint32_t interface_id;
  uint32_t reserved;
  uint64_t features;
} tecton_interface_header;

typedef int32_t(TECTON_PLUGIN_CALL *tecton_get_interface_fn)(void *userdata, uint32_t interface_id, uint16_t major, uint16_t minor, const tecton_interface_header **out_interface);

typedef void *(TECTON_PLUGIN_CALL *tecton_alloc_fn)(void *userdata, size_t size, size_t alignment);
typedef void(TECTON_PLUGIN_CALL *tecton_free_fn)(void *userdata, void *memory, size_t size, size_t alignment);
typedef void *(TECTON_PLUGIN_CALL *tecton_realloc_fn)(void *userdata, void *memory, size_t old_size, size_t new_size, size_t alignment);

typedef struct tecton_allocator {
  void *userdata; /* host-owned HostSlot; opaque */
  tecton_alloc_fn alloc;
  tecton_free_fn free;
  tecton_realloc_fn realloc;
  tecton_alloc_fn alloc_zeroed;
} tecton_allocator;

typedef void(TECTON_PLUGIN_CALL *tecton_log_fn)(void *userdata, uint32_t level, tecton_string_view message);
typedef void(TECTON_PLUGIN_CALL *tecton_timer_callback_fn)(void *userdata, uint64_t timer_id);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_scheduler_after_fn)(void *userdata, uint32_t delay_ticks, tecton_timer_callback_fn callback, void *callback_userdata, uint64_t *out_timer);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_scheduler_every_fn)(void *userdata, uint32_t interval_ticks, tecton_timer_callback_fn callback, void *callback_userdata, uint64_t *out_timer);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_log_is_enabled_fn)(void *userdata, uint32_t level);
typedef void(TECTON_PLUGIN_CALL *tecton_log_set_level_fn)(void *userdata, uint32_t level);
typedef void(TECTON_PLUGIN_CALL *tecton_log_set_scope_fn)(void *userdata, tecton_string_view scope);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_schema_of_fn)(void *userdata, tecton_string_view name, uint32_t flags, uint32_t *out_schema); /* low byte of flags is the schema version */
typedef struct tecton_registry_view tecton_registry_view;
typedef struct tecton_command_desc tecton_command_desc;
typedef struct tecton_command_call tecton_command_call;
typedef int32_t(TECTON_PLUGIN_CALL *tecton_registry_fn)(void *userdata, tecton_registry_view *out);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_command_handler_fn)(const tecton_command_call *call);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_command_register_fn)(void *userdata, const tecton_command_desc *desc, uint64_t *out_command);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_command_unregister_fn)(void *userdata, uint64_t command);
typedef void(TECTON_PLUGIN_CALL *tecton_command_mark_dirty_fn)(void *userdata);

struct tecton_host_api {
  uint32_t struct_size;
  uint16_t abi_major;
  uint16_t abi_minor;
  uint32_t plugin_id;
  void *userdata; /* host-owned HostSlot; opaque */
  tecton_allocator allocator;
  tecton_log_fn log;
  tecton_event_subscribe_fn event_subscribe;
  tecton_event_unsubscribe_fn event_unsubscribe;
  tecton_emit_custom_fn emit_custom;
  tecton_get_interface_fn get_interface;
  tecton_scheduler_every_fn every;
  uint64_t features;
};

typedef struct tecton_snapshot_header {
  uint32_t struct_size;
  uint16_t version;
  uint16_t reserved;
} tecton_snapshot_header;

typedef struct tecton_world_snapshot {
  tecton_snapshot_header header;
  uint64_t handle;
  tecton_string_view name; /* borrowed for this call */
} tecton_world_snapshot;

typedef struct tecton_player_snapshot {
  tecton_snapshot_header header;
  uint64_t handle;
  int64_t runtime_id;
  tecton_string_view name;      /* borrowed for this call */
  tecton_string_view uuid;      /* borrowed for this call */
  uint64_t world;
  tecton_string_view dimension; /* borrowed for this call */
  float x;
  float y;
  float z;
  float yaw;
  float pitch;
  uint32_t gamemode;
  uint32_t spawned;
} tecton_player_snapshot;

typedef struct tecton_block_box {
  int32_t min_x;
  int32_t min_y;
  int32_t min_z;
  int32_t max_x;
  int32_t max_y;
  int32_t max_z;
} tecton_block_box;

typedef struct tecton_entity_snapshot {
  tecton_snapshot_header header;
  uint64_t handle;
  int64_t runtime_id;
  tecton_string_view type;      /* borrowed for this call */
  uint64_t world;
  tecton_string_view dimension; /* borrowed for this call */
  float x;
  float y;
  float z;
} tecton_entity_snapshot;

typedef struct tecton_item_snapshot {
  tecton_snapshot_header header;
  uint64_t handle;
  int32_t network_id;
  uint16_t max_stack_size;
  uint8_t stackable;
  uint8_t reserved[5];
  tecton_string_view identifier; /* borrowed for this call */
} tecton_item_snapshot;

typedef struct tecton_block_snapshot {
  tecton_snapshot_header header;
  uint64_t world;
  tecton_string_view dimension; /* borrowed for this call */
  int32_t x;
  int32_t y;
  int32_t z;
  int32_t network_id;
  tecton_string_view identifier; /* borrowed for this call */
} tecton_block_snapshot;

typedef struct tecton_inventory_item_snapshot {
  tecton_snapshot_header header;
  uint8_t present;
  uint8_t reserved[3];
  uint16_t count;
  uint16_t reserved_count;
  int32_t network_id;
  uint32_t metadata;
  tecton_string_view identifier; /* borrowed for this call */
} tecton_inventory_item_snapshot;

typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_find_fn)(void *userdata, tecton_string_view name, uint64_t *handle);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_get_snapshot_fn)(void *userdata, uint64_t handle, tecton_world_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_set_block_fn)(void *userdata, uint64_t world, tecton_string_view dimension, int32_t x, int32_t y, int32_t z, tecton_string_view block);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_get_block_state_fn)(void *userdata, uint64_t world, tecton_string_view dimension, int32_t x, int32_t y, int32_t z, uint32_t *state);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_set_block_state_fn)(void *userdata, uint64_t world, tecton_string_view dimension, int32_t x, int32_t y, int32_t z, uint32_t state, uint32_t flags);
typedef void(TECTON_PLUGIN_CALL *tecton_block_callback_fn)(void *userdata, int32_t x, int32_t y, int32_t z, uint32_t state);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_world_for_each_in_box_fn)(void *userdata, uint64_t world, tecton_string_view dimension, tecton_block_box box, tecton_block_callback_fn callback, void *callback_userdata);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_players_count_fn)(void *userdata, size_t *count);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_players_get_snapshot_fn)(void *userdata, uint64_t handle, tecton_player_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_players_get_by_index_fn)(void *userdata, size_t index, tecton_player_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_players_get_by_runtime_fn)(void *userdata, int64_t runtime_id, tecton_player_snapshot *snapshot, size_t snapshot_size);
typedef void(TECTON_PLUGIN_CALL *tecton_player_callback_fn)(void *userdata, const tecton_player_snapshot *snapshot);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_players_for_each_fn)(void *userdata, tecton_player_callback_fn callback, void *callback_userdata);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_entities_count_fn)(void *userdata, uint64_t world, tecton_string_view dimension, size_t *count);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_entities_get_snapshot_fn)(void *userdata, uint64_t handle, tecton_entity_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_entities_get_by_index_fn)(void *userdata, uint64_t world, tecton_string_view dimension, size_t index, tecton_entity_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_entities_get_by_runtime_fn)(void *userdata, uint64_t world, tecton_string_view dimension, int64_t runtime_id, tecton_entity_snapshot *snapshot, size_t snapshot_size);
typedef void(TECTON_PLUGIN_CALL *tecton_entity_callback_fn)(void *userdata, const tecton_entity_snapshot *snapshot);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_entities_for_each_fn)(void *userdata, uint64_t world, tecton_string_view dimension, tecton_entity_callback_fn callback, void *callback_userdata);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_items_count_fn)(void *userdata, size_t *count);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_items_get_snapshot_fn)(void *userdata, uint64_t handle, tecton_item_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_items_get_by_index_fn)(void *userdata, size_t index, tecton_item_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_items_get_by_network_id_fn)(void *userdata, int32_t network_id, tecton_item_snapshot *snapshot, size_t snapshot_size);
typedef void(TECTON_PLUGIN_CALL *tecton_item_callback_fn)(void *userdata, const tecton_item_snapshot *snapshot);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_items_for_each_fn)(void *userdata, tecton_item_callback_fn callback, void *callback_userdata);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_blocks_get_snapshot_fn)(void *userdata, uint64_t world, tecton_string_view dimension, int32_t x, int32_t y, int32_t z, tecton_block_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_blocks_resolve_name_fn)(void *userdata, tecton_string_view name, uint32_t *state);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_inventory_get_size_fn)(void *userdata, uint64_t player, uint32_t *size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_inventory_get_item_fn)(void *userdata, uint64_t player, uint32_t slot, tecton_inventory_item_snapshot *snapshot, size_t snapshot_size);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_core_get_tick_fn)(void *userdata, uint64_t *tick);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_core_get_state_fn)(void *userdata, uint32_t *state);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_scheduler_cancel_fn)(void *userdata, uint64_t timer);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_scheduler_cancel_owner_fn)(void *userdata);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_network_send_fn)(void *userdata, uint64_t player, tecton_string_view packet, uint32_t priority);
typedef int32_t(TECTON_PLUGIN_CALL *tecton_network_broadcast_fn)(void *userdata, tecton_string_view packet, uint32_t priority);

typedef struct tecton_world_api {
  tecton_interface_header header;
  tecton_world_find_fn find;
  tecton_world_get_snapshot_fn get_snapshot;
  tecton_world_set_block_fn set_block;
  tecton_world_get_block_state_fn get_block_state;
  tecton_world_set_block_state_fn set_block_state;
  tecton_world_for_each_in_box_fn for_each_in_box;
} tecton_world_api;

typedef struct tecton_players_api {
  tecton_interface_header header;
  tecton_players_count_fn count;
  tecton_players_get_snapshot_fn get_snapshot;
  tecton_players_get_by_index_fn get_by_index;
  tecton_players_get_by_runtime_fn get_by_runtime;
  tecton_players_for_each_fn for_each;
} tecton_players_api;

typedef struct tecton_entities_api {
  tecton_interface_header header;
  tecton_entities_count_fn count;
  tecton_entities_get_snapshot_fn get_snapshot;
  tecton_entities_get_by_index_fn get_by_index;
  tecton_entities_get_by_runtime_fn get_by_runtime;
  tecton_entities_for_each_fn for_each;
} tecton_entities_api;

typedef struct tecton_items_api {
  tecton_interface_header header;
  tecton_items_count_fn count;
  tecton_items_get_snapshot_fn get_snapshot;
  tecton_items_get_by_index_fn get_by_index;
  tecton_items_get_by_network_id_fn get_by_network_id;
  tecton_items_for_each_fn for_each;
} tecton_items_api;

typedef struct tecton_blocks_api {
  tecton_interface_header header;
  tecton_blocks_get_snapshot_fn get_snapshot;
  tecton_blocks_resolve_name_fn resolve_name;
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
  tecton_scheduler_after_fn after;
  tecton_scheduler_every_fn every;
  tecton_scheduler_cancel_fn cancel;
  tecton_scheduler_cancel_owner_fn cancel_owner;
} tecton_scheduler_api;

typedef struct tecton_network_api {
  tecton_interface_header header;
  tecton_network_send_fn send;
  tecton_network_broadcast_fn broadcast;
} tecton_network_api;

typedef struct tecton_logging_api {
  tecton_interface_header header;
  tecton_log_fn log;
  tecton_log_is_enabled_fn is_enabled;
  tecton_log_set_level_fn set_level;
  tecton_log_set_scope_fn set_scope;
} tecton_logging_api;

typedef struct tecton_events_api {
  tecton_interface_header header;
  tecton_event_subscribe_fn subscribe;
  tecton_event_unsubscribe_fn unsubscribe;
  tecton_emit_custom_fn emit;
  tecton_emit_custom_fn emit_immediate;
  tecton_schema_of_fn schema_of;
} tecton_events_api;

typedef struct tecton_registry_view {
  const void *data; /* borrowed; core-owned; valid until on_unload */
  size_t count;
  size_t stride;
  uint32_t element_version;
  uint32_t reserved;
} tecton_registry_view;

typedef struct tecton_block_state_entry {
  int32_t network_id;
  uint32_t reserved;
  tecton_string_view identifier; /* borrowed; core-owned */
} tecton_block_state_entry;

typedef struct tecton_item_entry {
  int32_t network_id;
  uint16_t max_stack_size;
  uint8_t stackable;
  uint8_t reserved;
  tecton_string_view identifier; /* borrowed; core-owned */
} tecton_item_entry;

typedef struct tecton_entity_type_entry {
  int32_t network_id;
  uint32_t reserved;
  tecton_string_view identifier; /* borrowed; core-owned */
} tecton_entity_type_entry;

typedef struct tecton_registries_api {
  tecton_interface_header header;
  tecton_registry_fn block_states;
  tecton_registry_fn items;
  tecton_registry_fn entity_types;
} tecton_registries_api;

typedef struct tecton_command_desc {
  uint32_t struct_size;
  uint32_t flags; /* reserved; must be 0 */
  tecton_string_view name;         /* borrowed for the call; copied by host */
  tecton_string_view description;  /* borrowed for the call; copied by host */
  tecton_string_view permission;   /* borrowed for the call; copied by host */
  const tecton_string_view *aliases; /* borrowed for the call; copied by host */
  uint32_t alias_count;
  uint32_t reserved;
  tecton_command_handler_fn handler; /* plugin-owned; runs on the tick thread */
  void *userdata;                    /* plugin-owned; passed back to the handler */
} tecton_command_desc;

struct tecton_command_call {
  uint32_t struct_size;
  uint32_t argc;
  const tecton_string_view *argv; /* borrowed; argv[0] is the command name */
  tecton_string_view raw_line;    /* borrowed; no leading '/' */
  uint64_t player;                /* 0 for the console */
  uint64_t world;                 /* 0 when the executor has no world */
  void *userdata;                 /* plugin-owned; as registered in the descriptor */
};

typedef struct tecton_commands_api {
  tecton_interface_header header;
  tecton_command_register_fn register_command;
  tecton_command_unregister_fn unregister;
  tecton_command_mark_dirty_fn mark_dirty;
} tecton_commands_api;

typedef int32_t(TECTON_PLUGIN_CALL *tecton_plugin_query_fn)(const tecton_host_query *query, tecton_plugin_info *info);

TECTON_PLUGIN_EXPORT int32_t TECTON_PLUGIN_CALL tecton_plugin_query(const tecton_host_query *query, tecton_plugin_info *info);

TECTON_STATIC_ASSERT(sizeof(void *) == 8, "Tecton plugin ABI requires LP64: sizeof(void*) != 8");
TECTON_STATIC_ASSERT(sizeof(size_t) == 8, "Tecton plugin ABI requires LP64: sizeof(size_t) != 8");

#define TECTON_LAYOUT_SIZE(type, size) TECTON_STATIC_ASSERT(sizeof(type) == (size), #type " sizeof drift")
#define TECTON_LAYOUT_OFFSET(type, field, offset) TECTON_STATIC_ASSERT(offsetof(type, field) == (offset), #type "." #field " offset drift")

TECTON_LAYOUT_SIZE(tecton_string_view, 16);
TECTON_LAYOUT_OFFSET(tecton_string_view, data, 0);
TECTON_LAYOUT_OFFSET(tecton_string_view, length, 8);

TECTON_LAYOUT_SIZE(tecton_api_version, 8);
TECTON_LAYOUT_OFFSET(tecton_api_version, major, 0);
TECTON_LAYOUT_OFFSET(tecton_api_version, minor, 2);
TECTON_LAYOUT_OFFSET(tecton_api_version, patch, 4);
TECTON_LAYOUT_OFFSET(tecton_api_version, reserved, 6);

TECTON_LAYOUT_SIZE(tecton_host_query, 40);
TECTON_LAYOUT_OFFSET(tecton_host_query, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_host_query, abi_major, 4);
TECTON_LAYOUT_OFFSET(tecton_host_query, abi_minor, 8);
TECTON_LAYOUT_OFFSET(tecton_host_query, reserved, 12);
TECTON_LAYOUT_OFFSET(tecton_host_query, abi_fingerprint, 16);
TECTON_LAYOUT_OFFSET(tecton_host_query, host_features, 24);
TECTON_LAYOUT_OFFSET(tecton_host_query, tick_rate, 32);
TECTON_LAYOUT_OFFSET(tecton_host_query, reserved2, 36);

TECTON_LAYOUT_SIZE(tecton_plugin_info, 56);
TECTON_LAYOUT_OFFSET(tecton_plugin_info, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_plugin_info, status, 4);
TECTON_LAYOUT_OFFSET(tecton_plugin_info, abi_major, 8);
TECTON_LAYOUT_OFFSET(tecton_plugin_info, abi_minor, 12);
TECTON_LAYOUT_OFFSET(tecton_plugin_info, abi_fingerprint, 16);
TECTON_LAYOUT_OFFSET(tecton_plugin_info, descriptor, 24);
TECTON_LAYOUT_OFFSET(tecton_plugin_info, diagnostic, 32);
TECTON_LAYOUT_OFFSET(tecton_plugin_info, reserved, 48);

TECTON_LAYOUT_SIZE(tecton_plugin_metadata, 80);
TECTON_LAYOUT_OFFSET(tecton_plugin_metadata, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_plugin_metadata, plugin_flags, 4);
TECTON_LAYOUT_OFFSET(tecton_plugin_metadata, name, 8);
TECTON_LAYOUT_OFFSET(tecton_plugin_metadata, version, 24);
TECTON_LAYOUT_OFFSET(tecton_plugin_metadata, description, 40);
TECTON_LAYOUT_OFFSET(tecton_plugin_metadata, api, 56);
TECTON_LAYOUT_OFFSET(tecton_plugin_metadata, required_features, 64);
TECTON_LAYOUT_OFFSET(tecton_plugin_metadata, optional_features, 72);

TECTON_LAYOUT_SIZE(tecton_plugin_descriptor, 136);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, descriptor_version, 4);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, abi_fingerprint, 8);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, metadata, 16);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, on_load, 96);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, on_start, 104);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, on_shutdown, 112);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, on_unload, 120);
TECTON_LAYOUT_OFFSET(tecton_plugin_descriptor, on_ready, 128);

TECTON_LAYOUT_SIZE(tecton_plugin_context, 32);
TECTON_LAYOUT_OFFSET(tecton_plugin_context, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_plugin_context, plugin_id, 4);
TECTON_LAYOUT_OFFSET(tecton_plugin_context, host, 8);
TECTON_LAYOUT_OFFSET(tecton_plugin_context, engine, 16);
TECTON_LAYOUT_OFFSET(tecton_plugin_context, reserved, 24);

TECTON_LAYOUT_SIZE(tecton_allocator, 40);
TECTON_LAYOUT_OFFSET(tecton_allocator, userdata, 0);
TECTON_LAYOUT_OFFSET(tecton_allocator, alloc, 8);
TECTON_LAYOUT_OFFSET(tecton_allocator, free, 16);
TECTON_LAYOUT_OFFSET(tecton_allocator, realloc, 24);
TECTON_LAYOUT_OFFSET(tecton_allocator, alloc_zeroed, 32);

TECTON_LAYOUT_SIZE(tecton_host_api, 120);
TECTON_LAYOUT_OFFSET(tecton_host_api, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_host_api, abi_major, 4);
TECTON_LAYOUT_OFFSET(tecton_host_api, abi_minor, 6);
TECTON_LAYOUT_OFFSET(tecton_host_api, plugin_id, 8);
TECTON_LAYOUT_OFFSET(tecton_host_api, userdata, 16);
TECTON_LAYOUT_OFFSET(tecton_host_api, allocator, 24);
TECTON_LAYOUT_OFFSET(tecton_host_api, log, 64);
TECTON_LAYOUT_OFFSET(tecton_host_api, event_subscribe, 72);
TECTON_LAYOUT_OFFSET(tecton_host_api, event_unsubscribe, 80);
TECTON_LAYOUT_OFFSET(tecton_host_api, emit_custom, 88);
TECTON_LAYOUT_OFFSET(tecton_host_api, get_interface, 96);
TECTON_LAYOUT_OFFSET(tecton_host_api, every, 104);
TECTON_LAYOUT_OFFSET(tecton_host_api, features, 112);

TECTON_LAYOUT_SIZE(tecton_interface_header, 24);
TECTON_LAYOUT_OFFSET(tecton_interface_header, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_interface_header, major, 4);
TECTON_LAYOUT_OFFSET(tecton_interface_header, minor, 6);
TECTON_LAYOUT_OFFSET(tecton_interface_header, interface_id, 8);
TECTON_LAYOUT_OFFSET(tecton_interface_header, reserved, 12);
TECTON_LAYOUT_OFFSET(tecton_interface_header, features, 16);

TECTON_LAYOUT_SIZE(tecton_event_view, 40);
TECTON_LAYOUT_OFFSET(tecton_event_view, data, 0);
TECTON_LAYOUT_OFFSET(tecton_event_view, data_size, 8);
TECTON_LAYOUT_OFFSET(tecton_event_view, result, 16);
TECTON_LAYOUT_OFFSET(tecton_event_view, schema, 24);
TECTON_LAYOUT_OFFSET(tecton_event_view, event_id, 28);
TECTON_LAYOUT_OFFSET(tecton_event_view, phase, 32);
TECTON_LAYOUT_OFFSET(tecton_event_view, flags, 34);

TECTON_LAYOUT_SIZE(tecton_server_tick_event, 8);
TECTON_LAYOUT_OFFSET(tecton_server_tick_event, tick, 0);

TECTON_LAYOUT_SIZE(tecton_player_event, 8);
TECTON_LAYOUT_OFFSET(tecton_player_event, handle, 0);

TECTON_LAYOUT_SIZE(tecton_player_join_event, 16);
TECTON_LAYOUT_OFFSET(tecton_player_join_event, handle, 0);
TECTON_LAYOUT_OFFSET(tecton_player_join_event, runtime_id, 8);

TECTON_LAYOUT_SIZE(tecton_player_ref_event, 16);
TECTON_LAYOUT_OFFSET(tecton_player_ref_event, handle, 0);
TECTON_LAYOUT_OFFSET(tecton_player_ref_event, runtime_id, 8);

TECTON_LAYOUT_SIZE(tecton_player_chat_event, 32);
TECTON_LAYOUT_OFFSET(tecton_player_chat_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_player_chat_event, message, 8);
TECTON_LAYOUT_OFFSET(tecton_player_chat_event, flags, 24);
TECTON_LAYOUT_OFFSET(tecton_player_chat_event, reserved, 28);

TECTON_LAYOUT_SIZE(tecton_item_use_event, 32);
TECTON_LAYOUT_OFFSET(tecton_item_use_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_item_use_event, identifier, 8);
TECTON_LAYOUT_OFFSET(tecton_item_use_event, flags, 24);
TECTON_LAYOUT_OFFSET(tecton_item_use_event, reserved, 28);

TECTON_LAYOUT_SIZE(tecton_player_move_event, 40);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, from_x, 8);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, from_y, 12);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, from_z, 16);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, to_x, 20);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, to_y, 24);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, to_z, 28);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, on_ground, 32);
TECTON_LAYOUT_OFFSET(tecton_player_move_event, reserved, 36);

TECTON_LAYOUT_SIZE(tecton_damage_event, 32);
TECTON_LAYOUT_OFFSET(tecton_damage_event, victim_runtime, 0);
TECTON_LAYOUT_OFFSET(tecton_damage_event, attacker_runtime, 8);
TECTON_LAYOUT_OFFSET(tecton_damage_event, amount, 16);
TECTON_LAYOUT_OFFSET(tecton_damage_event, cause, 20);
TECTON_LAYOUT_OFFSET(tecton_damage_event, reserved, 24);

TECTON_LAYOUT_SIZE(tecton_block_place_event, 32);
TECTON_LAYOUT_OFFSET(tecton_block_place_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_block_place_event, x, 8);
TECTON_LAYOUT_OFFSET(tecton_block_place_event, y, 12);
TECTON_LAYOUT_OFFSET(tecton_block_place_event, z, 16);
TECTON_LAYOUT_OFFSET(tecton_block_place_event, network_id, 20);
TECTON_LAYOUT_OFFSET(tecton_block_place_event, reserved, 24);

TECTON_LAYOUT_SIZE(tecton_block_break_event, 32);
TECTON_LAYOUT_OFFSET(tecton_block_break_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_block_break_event, x, 8);
TECTON_LAYOUT_OFFSET(tecton_block_break_event, y, 12);
TECTON_LAYOUT_OFFSET(tecton_block_break_event, z, 16);
TECTON_LAYOUT_OFFSET(tecton_block_break_event, network_id, 20);
TECTON_LAYOUT_OFFSET(tecton_block_break_event, reserved, 24);

TECTON_LAYOUT_SIZE(tecton_inventory_event, 16);
TECTON_LAYOUT_OFFSET(tecton_inventory_event, handle, 0);
TECTON_LAYOUT_OFFSET(tecton_inventory_event, container_id, 8);
TECTON_LAYOUT_OFFSET(tecton_inventory_event, reserved, 12);

TECTON_LAYOUT_SIZE(tecton_inventory_click_event, 16);
TECTON_LAYOUT_OFFSET(tecton_inventory_click_event, handle, 0);
TECTON_LAYOUT_OFFSET(tecton_inventory_click_event, slot, 8);
TECTON_LAYOUT_OFFSET(tecton_inventory_click_event, button, 10);
TECTON_LAYOUT_OFFSET(tecton_inventory_click_event, reserved, 11);
TECTON_LAYOUT_OFFSET(tecton_inventory_click_event, reserved2, 12);

TECTON_LAYOUT_SIZE(tecton_transaction_event, 32);
TECTON_LAYOUT_OFFSET(tecton_transaction_event, handle, 0);
TECTON_LAYOUT_OFFSET(tecton_transaction_event, transaction_id, 8);
TECTON_LAYOUT_OFFSET(tecton_transaction_event, committed, 24);
TECTON_LAYOUT_OFFSET(tecton_transaction_event, reserved, 28);

TECTON_LAYOUT_SIZE(tecton_entity_combust_event, 24);
TECTON_LAYOUT_OFFSET(tecton_entity_combust_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_entity_combust_event, instigator_runtime, 8);
TECTON_LAYOUT_OFFSET(tecton_entity_combust_event, duration, 16);
TECTON_LAYOUT_OFFSET(tecton_entity_combust_event, source, 20);

TECTON_LAYOUT_SIZE(tecton_enchant_event, 24);
TECTON_LAYOUT_OFFSET(tecton_enchant_event, item_handle, 0);
TECTON_LAYOUT_OFFSET(tecton_enchant_event, actor_runtime, 8);
TECTON_LAYOUT_OFFSET(tecton_enchant_event, enchantment_id, 16);
TECTON_LAYOUT_OFFSET(tecton_enchant_event, previous_level, 20);
TECTON_LAYOUT_OFFSET(tecton_enchant_event, level, 21);
TECTON_LAYOUT_OFFSET(tecton_enchant_event, source, 22);
TECTON_LAYOUT_OFFSET(tecton_enchant_event, reserved, 23);

TECTON_LAYOUT_SIZE(tecton_entity_spawn_event, 16);
TECTON_LAYOUT_OFFSET(tecton_entity_spawn_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_entity_spawn_event, reserved, 8);

TECTON_LAYOUT_SIZE(tecton_entity_despawn_event, 16);
TECTON_LAYOUT_OFFSET(tecton_entity_despawn_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_entity_despawn_event, cause, 8);
TECTON_LAYOUT_OFFSET(tecton_entity_despawn_event, reserved, 12);

TECTON_LAYOUT_SIZE(tecton_entity_damage_event, 32);
TECTON_LAYOUT_OFFSET(tecton_entity_damage_event, target_runtime, 0);
TECTON_LAYOUT_OFFSET(tecton_entity_damage_event, source_runtime, 8);
TECTON_LAYOUT_OFFSET(tecton_entity_damage_event, amount, 16);
TECTON_LAYOUT_OFFSET(tecton_entity_damage_event, cause, 20);
TECTON_LAYOUT_OFFSET(tecton_entity_damage_event, reserved, 24);

TECTON_LAYOUT_SIZE(tecton_entity_death_event, 32);
TECTON_LAYOUT_OFFSET(tecton_entity_death_event, runtime_id, 0);
TECTON_LAYOUT_OFFSET(tecton_entity_death_event, killer_runtime, 8);
TECTON_LAYOUT_OFFSET(tecton_entity_death_event, x, 16);
TECTON_LAYOUT_OFFSET(tecton_entity_death_event, y, 20);
TECTON_LAYOUT_OFFSET(tecton_entity_death_event, z, 24);
TECTON_LAYOUT_OFFSET(tecton_entity_death_event, reserved, 28);

TECTON_LAYOUT_SIZE(tecton_entity_interact_event, 24);
TECTON_LAYOUT_OFFSET(tecton_entity_interact_event, target_runtime, 0);
TECTON_LAYOUT_OFFSET(tecton_entity_interact_event, player_runtime, 8);
TECTON_LAYOUT_OFFSET(tecton_entity_interact_event, action, 16);
TECTON_LAYOUT_OFFSET(tecton_entity_interact_event, reserved, 20);

TECTON_LAYOUT_SIZE(tecton_snapshot_header, 8);
TECTON_LAYOUT_OFFSET(tecton_snapshot_header, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_snapshot_header, version, 4);
TECTON_LAYOUT_OFFSET(tecton_snapshot_header, reserved, 6);

TECTON_LAYOUT_SIZE(tecton_world_snapshot, 32);
TECTON_LAYOUT_OFFSET(tecton_world_snapshot, header, 0);
TECTON_LAYOUT_OFFSET(tecton_world_snapshot, handle, 8);
TECTON_LAYOUT_OFFSET(tecton_world_snapshot, name, 16);

TECTON_LAYOUT_SIZE(tecton_player_snapshot, 112);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, header, 0);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, handle, 8);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, runtime_id, 16);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, name, 24);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, uuid, 40);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, world, 56);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, dimension, 64);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, x, 80);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, y, 84);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, z, 88);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, yaw, 92);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, pitch, 96);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, gamemode, 100);
TECTON_LAYOUT_OFFSET(tecton_player_snapshot, spawned, 104);

TECTON_LAYOUT_SIZE(tecton_block_box, 24);
TECTON_LAYOUT_OFFSET(tecton_block_box, min_x, 0);
TECTON_LAYOUT_OFFSET(tecton_block_box, min_y, 4);
TECTON_LAYOUT_OFFSET(tecton_block_box, min_z, 8);
TECTON_LAYOUT_OFFSET(tecton_block_box, max_x, 12);
TECTON_LAYOUT_OFFSET(tecton_block_box, max_y, 16);
TECTON_LAYOUT_OFFSET(tecton_block_box, max_z, 20);

TECTON_LAYOUT_SIZE(tecton_entity_snapshot, 80);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, header, 0);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, handle, 8);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, runtime_id, 16);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, type, 24);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, world, 40);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, dimension, 48);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, x, 64);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, y, 68);
TECTON_LAYOUT_OFFSET(tecton_entity_snapshot, z, 72);

TECTON_LAYOUT_SIZE(tecton_item_snapshot, 48);
TECTON_LAYOUT_OFFSET(tecton_item_snapshot, header, 0);
TECTON_LAYOUT_OFFSET(tecton_item_snapshot, handle, 8);
TECTON_LAYOUT_OFFSET(tecton_item_snapshot, network_id, 16);
TECTON_LAYOUT_OFFSET(tecton_item_snapshot, max_stack_size, 20);
TECTON_LAYOUT_OFFSET(tecton_item_snapshot, stackable, 22);
TECTON_LAYOUT_OFFSET(tecton_item_snapshot, reserved, 23);
TECTON_LAYOUT_OFFSET(tecton_item_snapshot, identifier, 32);

TECTON_LAYOUT_SIZE(tecton_block_snapshot, 64);
TECTON_LAYOUT_OFFSET(tecton_block_snapshot, header, 0);
TECTON_LAYOUT_OFFSET(tecton_block_snapshot, world, 8);
TECTON_LAYOUT_OFFSET(tecton_block_snapshot, dimension, 16);
TECTON_LAYOUT_OFFSET(tecton_block_snapshot, x, 32);
TECTON_LAYOUT_OFFSET(tecton_block_snapshot, y, 36);
TECTON_LAYOUT_OFFSET(tecton_block_snapshot, z, 40);
TECTON_LAYOUT_OFFSET(tecton_block_snapshot, network_id, 44);
TECTON_LAYOUT_OFFSET(tecton_block_snapshot, identifier, 48);

TECTON_LAYOUT_SIZE(tecton_inventory_item_snapshot, 40);
TECTON_LAYOUT_OFFSET(tecton_inventory_item_snapshot, header, 0);
TECTON_LAYOUT_OFFSET(tecton_inventory_item_snapshot, present, 8);
TECTON_LAYOUT_OFFSET(tecton_inventory_item_snapshot, reserved, 9);
TECTON_LAYOUT_OFFSET(tecton_inventory_item_snapshot, count, 12);
TECTON_LAYOUT_OFFSET(tecton_inventory_item_snapshot, reserved_count, 14);
TECTON_LAYOUT_OFFSET(tecton_inventory_item_snapshot, network_id, 16);
TECTON_LAYOUT_OFFSET(tecton_inventory_item_snapshot, metadata, 20);
TECTON_LAYOUT_OFFSET(tecton_inventory_item_snapshot, identifier, 24);

TECTON_LAYOUT_SIZE(tecton_world_api, 72);
TECTON_LAYOUT_OFFSET(tecton_world_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_world_api, find, 24);
TECTON_LAYOUT_OFFSET(tecton_world_api, get_snapshot, 32);
TECTON_LAYOUT_OFFSET(tecton_world_api, set_block, 40);
TECTON_LAYOUT_OFFSET(tecton_world_api, get_block_state, 48);
TECTON_LAYOUT_OFFSET(tecton_world_api, set_block_state, 56);
TECTON_LAYOUT_OFFSET(tecton_world_api, for_each_in_box, 64);

TECTON_LAYOUT_SIZE(tecton_players_api, 64);
TECTON_LAYOUT_OFFSET(tecton_players_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_players_api, count, 24);
TECTON_LAYOUT_OFFSET(tecton_players_api, get_snapshot, 32);
TECTON_LAYOUT_OFFSET(tecton_players_api, get_by_index, 40);
TECTON_LAYOUT_OFFSET(tecton_players_api, get_by_runtime, 48);
TECTON_LAYOUT_OFFSET(tecton_players_api, for_each, 56);

TECTON_LAYOUT_SIZE(tecton_entities_api, 64);
TECTON_LAYOUT_OFFSET(tecton_entities_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_entities_api, count, 24);
TECTON_LAYOUT_OFFSET(tecton_entities_api, get_snapshot, 32);
TECTON_LAYOUT_OFFSET(tecton_entities_api, get_by_index, 40);
TECTON_LAYOUT_OFFSET(tecton_entities_api, get_by_runtime, 48);
TECTON_LAYOUT_OFFSET(tecton_entities_api, for_each, 56);

TECTON_LAYOUT_SIZE(tecton_items_api, 64);
TECTON_LAYOUT_OFFSET(tecton_items_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_items_api, count, 24);
TECTON_LAYOUT_OFFSET(tecton_items_api, get_snapshot, 32);
TECTON_LAYOUT_OFFSET(tecton_items_api, get_by_index, 40);
TECTON_LAYOUT_OFFSET(tecton_items_api, get_by_network_id, 48);
TECTON_LAYOUT_OFFSET(tecton_items_api, for_each, 56);

TECTON_LAYOUT_SIZE(tecton_blocks_api, 40);
TECTON_LAYOUT_OFFSET(tecton_blocks_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_blocks_api, get_snapshot, 24);
TECTON_LAYOUT_OFFSET(tecton_blocks_api, resolve_name, 32);

TECTON_LAYOUT_SIZE(tecton_inventories_api, 40);
TECTON_LAYOUT_OFFSET(tecton_inventories_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_inventories_api, get_size, 24);
TECTON_LAYOUT_OFFSET(tecton_inventories_api, get_item, 32);

TECTON_LAYOUT_SIZE(tecton_core_api, 40);
TECTON_LAYOUT_OFFSET(tecton_core_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_core_api, get_tick, 24);
TECTON_LAYOUT_OFFSET(tecton_core_api, get_state, 32);

TECTON_LAYOUT_SIZE(tecton_scheduler_api, 56);
TECTON_LAYOUT_OFFSET(tecton_scheduler_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_scheduler_api, after, 24);
TECTON_LAYOUT_OFFSET(tecton_scheduler_api, every, 32);
TECTON_LAYOUT_OFFSET(tecton_scheduler_api, cancel, 40);
TECTON_LAYOUT_OFFSET(tecton_scheduler_api, cancel_owner, 48);

TECTON_LAYOUT_SIZE(tecton_network_api, 40);
TECTON_LAYOUT_OFFSET(tecton_network_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_network_api, send, 24);
TECTON_LAYOUT_OFFSET(tecton_network_api, broadcast, 32);

TECTON_LAYOUT_SIZE(tecton_logging_api, 56);
TECTON_LAYOUT_OFFSET(tecton_logging_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_logging_api, log, 24);
TECTON_LAYOUT_OFFSET(tecton_logging_api, is_enabled, 32);
TECTON_LAYOUT_OFFSET(tecton_logging_api, set_level, 40);
TECTON_LAYOUT_OFFSET(tecton_logging_api, set_scope, 48);

TECTON_LAYOUT_SIZE(tecton_events_api, 64);
TECTON_LAYOUT_OFFSET(tecton_events_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_events_api, subscribe, 24);
TECTON_LAYOUT_OFFSET(tecton_events_api, unsubscribe, 32);
TECTON_LAYOUT_OFFSET(tecton_events_api, emit, 40);
TECTON_LAYOUT_OFFSET(tecton_events_api, emit_immediate, 48);
TECTON_LAYOUT_OFFSET(tecton_events_api, schema_of, 56);

TECTON_LAYOUT_SIZE(tecton_registry_view, 32);
TECTON_LAYOUT_OFFSET(tecton_registry_view, data, 0);
TECTON_LAYOUT_OFFSET(tecton_registry_view, count, 8);
TECTON_LAYOUT_OFFSET(tecton_registry_view, stride, 16);
TECTON_LAYOUT_OFFSET(tecton_registry_view, element_version, 24);
TECTON_LAYOUT_OFFSET(tecton_registry_view, reserved, 28);

TECTON_LAYOUT_SIZE(tecton_block_state_entry, 24);
TECTON_LAYOUT_OFFSET(tecton_block_state_entry, network_id, 0);
TECTON_LAYOUT_OFFSET(tecton_block_state_entry, reserved, 4);
TECTON_LAYOUT_OFFSET(tecton_block_state_entry, identifier, 8);

TECTON_LAYOUT_SIZE(tecton_item_entry, 24);
TECTON_LAYOUT_OFFSET(tecton_item_entry, network_id, 0);
TECTON_LAYOUT_OFFSET(tecton_item_entry, max_stack_size, 4);
TECTON_LAYOUT_OFFSET(tecton_item_entry, stackable, 6);
TECTON_LAYOUT_OFFSET(tecton_item_entry, reserved, 7);
TECTON_LAYOUT_OFFSET(tecton_item_entry, identifier, 8);

TECTON_LAYOUT_SIZE(tecton_entity_type_entry, 24);
TECTON_LAYOUT_OFFSET(tecton_entity_type_entry, network_id, 0);
TECTON_LAYOUT_OFFSET(tecton_entity_type_entry, reserved, 4);
TECTON_LAYOUT_OFFSET(tecton_entity_type_entry, identifier, 8);

TECTON_LAYOUT_SIZE(tecton_registries_api, 48);
TECTON_LAYOUT_OFFSET(tecton_registries_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_registries_api, block_states, 24);
TECTON_LAYOUT_OFFSET(tecton_registries_api, items, 32);
TECTON_LAYOUT_OFFSET(tecton_registries_api, entity_types, 40);

TECTON_LAYOUT_SIZE(tecton_command_desc, 88);
TECTON_LAYOUT_OFFSET(tecton_command_desc, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_command_desc, flags, 4);
TECTON_LAYOUT_OFFSET(tecton_command_desc, name, 8);
TECTON_LAYOUT_OFFSET(tecton_command_desc, description, 24);
TECTON_LAYOUT_OFFSET(tecton_command_desc, permission, 40);
TECTON_LAYOUT_OFFSET(tecton_command_desc, aliases, 56);
TECTON_LAYOUT_OFFSET(tecton_command_desc, alias_count, 64);
TECTON_LAYOUT_OFFSET(tecton_command_desc, reserved, 68);
TECTON_LAYOUT_OFFSET(tecton_command_desc, handler, 72);
TECTON_LAYOUT_OFFSET(tecton_command_desc, userdata, 80);

TECTON_LAYOUT_SIZE(tecton_command_call, 56);
TECTON_LAYOUT_OFFSET(tecton_command_call, struct_size, 0);
TECTON_LAYOUT_OFFSET(tecton_command_call, argc, 4);
TECTON_LAYOUT_OFFSET(tecton_command_call, argv, 8);
TECTON_LAYOUT_OFFSET(tecton_command_call, raw_line, 16);
TECTON_LAYOUT_OFFSET(tecton_command_call, player, 32);
TECTON_LAYOUT_OFFSET(tecton_command_call, world, 40);
TECTON_LAYOUT_OFFSET(tecton_command_call, userdata, 48);

TECTON_LAYOUT_SIZE(tecton_commands_api, 48);
TECTON_LAYOUT_OFFSET(tecton_commands_api, header, 0);
TECTON_LAYOUT_OFFSET(tecton_commands_api, register_command, 24);
TECTON_LAYOUT_OFFSET(tecton_commands_api, unregister, 32);
TECTON_LAYOUT_OFFSET(tecton_commands_api, mark_dirty, 40);

#define TECTON_ABI_FP_SEED UINT64_C(0xcbf29ce484222325)
#define TECTON_ABI_FP_PRIME UINT64_C(0x100000001b3)

#define TECTON_ABI_FP_BYTE(hash, octet) (((hash) ^ (uint64_t)(uint8_t)(octet)) * TECTON_ABI_FP_PRIME)

#define TECTON_ABI_FP_VALUE(hash, value)                                                                                                     \
  TECTON_ABI_FP_BYTE(                                                                                                                        \
      TECTON_ABI_FP_BYTE(                                                                                                                    \
          TECTON_ABI_FP_BYTE(                                                                                                                \
              TECTON_ABI_FP_BYTE(                                                                                                            \
                  TECTON_ABI_FP_BYTE(                                                                                                        \
                      TECTON_ABI_FP_BYTE(                                                                                                    \
                          TECTON_ABI_FP_BYTE(                                                                                                \
                              TECTON_ABI_FP_BYTE((hash), (uint64_t)(value) & UINT64_C(0xff)),                                             \
                              ((uint64_t)(value) >> 8) & UINT64_C(0xff)),                                                                \
                          ((uint64_t)(value) >> 16) & UINT64_C(0xff)),                                                               \
                      ((uint64_t)(value) >> 24) & UINT64_C(0xff)),                                                                   \
                  ((uint64_t)(value) >> 32) & UINT64_C(0xff)),                                                                       \
              ((uint64_t)(value) >> 40) & UINT64_C(0xff)),                                                                           \
          ((uint64_t)(value) >> 48) & UINT64_C(0xff)),                                                                               \
      ((uint64_t)(value) >> 56) & UINT64_C(0xff))

#define TECTON_ABI_FP_1(hash, a) TECTON_ABI_FP_VALUE((hash), (a))
#define TECTON_ABI_FP_2(hash, a, b) TECTON_ABI_FP_1(TECTON_ABI_FP_1((hash), (a)), (b))
#define TECTON_ABI_FP_3(hash, a, b, c) TECTON_ABI_FP_1(TECTON_ABI_FP_2((hash), (a), (b)), (c))
#define TECTON_ABI_FP_4(hash, a, b, c, d) TECTON_ABI_FP_1(TECTON_ABI_FP_3((hash), (a), (b), (c)), (d))
#define TECTON_ABI_FP_5(hash, a, b, c, d, e) TECTON_ABI_FP_1(TECTON_ABI_FP_4((hash), (a), (b), (c), (d)), (e))
#define TECTON_ABI_FP_6(hash, a, b, c, d, e, f) TECTON_ABI_FP_1(TECTON_ABI_FP_5((hash), (a), (b), (c), (d), (e)), (f))
#define TECTON_ABI_FP_7(hash, a, b, c, d, e, f, g) TECTON_ABI_FP_1(TECTON_ABI_FP_6((hash), (a), (b), (c), (d), (e), (f)), (g))
#define TECTON_ABI_FP_8(hash, a, b, c, d, e, f, g, i) TECTON_ABI_FP_1(TECTON_ABI_FP_7((hash), (a), (b), (c), (d), (e), (f), (g)), (i))
#define TECTON_ABI_FP_9(hash, a, b, c, d, e, f, g, i, j) TECTON_ABI_FP_1(TECTON_ABI_FP_8((hash), (a), (b), (c), (d), (e), (f), (g), (i)), (j))
#define TECTON_ABI_FP_10(hash, a, b, c, d, e, f, g, i, j, k) TECTON_ABI_FP_1(TECTON_ABI_FP_9((hash), (a), (b), (c), (d), (e), (f), (g), (i), (j)), (k))
#define TECTON_ABI_FP_11(hash, a, b, c, d, e, f, g, i, j, k, l) TECTON_ABI_FP_1(TECTON_ABI_FP_10((hash), (a), (b), (c), (d), (e), (f), (g), (i), (j), (k)), (l))
#define TECTON_ABI_FP_12(hash, a, b, c, d, e, f, g, i, j, k, l, m) TECTON_ABI_FP_1(TECTON_ABI_FP_11((hash), (a), (b), (c), (d), (e), (f), (g), (i), (j), (k), (l)), (m))
#define TECTON_ABI_FP_13(hash, a, b, c, d, e, f, g, i, j, k, l, m, n) TECTON_ABI_FP_1(TECTON_ABI_FP_12((hash), (a), (b), (c), (d), (e), (f), (g), (i), (j), (k), (l), (m)), (n))
#define TECTON_ABI_FP_14(hash, a, b, c, d, e, f, g, i, j, k, l, m, n, o) TECTON_ABI_FP_1(TECTON_ABI_FP_13((hash), (a), (b), (c), (d), (e), (f), (g), (i), (j), (k), (l), (m), (n)), (o))
#define TECTON_ABI_FP_15(hash, a, b, c, d, e, f, g, i, j, k, l, m, n, o, p) TECTON_ABI_FP_1(TECTON_ABI_FP_14((hash), (a), (b), (c), (d), (e), (f), (g), (i), (j), (k), (l), (m), (n), (o)), (p))
#define TECTON_ABI_FP_16(hash, a, b, c, d, e, f, g, i, j, k, l, m, n, o, p, q) TECTON_ABI_FP_1(TECTON_ABI_FP_15((hash), (a), (b), (c), (d), (e), (f), (g), (i), (j), (k), (l), (m), (n), (o), (p)), (q))

#define TECTON_ABI_FP_STRING_VIEW(hash) \
  TECTON_ABI_FP_3((hash), sizeof(tecton_string_view), offsetof(tecton_string_view, data), offsetof(tecton_string_view, length))

#define TECTON_ABI_FP_API_VERSION(hash) \
  TECTON_ABI_FP_5((hash), sizeof(tecton_api_version), offsetof(tecton_api_version, major), offsetof(tecton_api_version, minor), offsetof(tecton_api_version, patch), offsetof(tecton_api_version, reserved))

#define TECTON_ABI_FP_HOST_QUERY(hash) \
  TECTON_ABI_FP_9((hash), sizeof(tecton_host_query), offsetof(tecton_host_query, struct_size), offsetof(tecton_host_query, abi_major), offsetof(tecton_host_query, abi_minor), offsetof(tecton_host_query, reserved), offsetof(tecton_host_query, abi_fingerprint), offsetof(tecton_host_query, host_features), offsetof(tecton_host_query, tick_rate), offsetof(tecton_host_query, reserved2))

#define TECTON_ABI_FP_PLUGIN_INFO(hash) \
  TECTON_ABI_FP_9((hash), sizeof(tecton_plugin_info), offsetof(tecton_plugin_info, struct_size), offsetof(tecton_plugin_info, status), offsetof(tecton_plugin_info, abi_major), offsetof(tecton_plugin_info, abi_minor), offsetof(tecton_plugin_info, abi_fingerprint), offsetof(tecton_plugin_info, descriptor), offsetof(tecton_plugin_info, diagnostic), offsetof(tecton_plugin_info, reserved))

#define TECTON_ABI_FP_METADATA(hash) \
  TECTON_ABI_FP_9((hash), sizeof(tecton_plugin_metadata), offsetof(tecton_plugin_metadata, struct_size), offsetof(tecton_plugin_metadata, plugin_flags), offsetof(tecton_plugin_metadata, name), offsetof(tecton_plugin_metadata, version), offsetof(tecton_plugin_metadata, description), offsetof(tecton_plugin_metadata, api), offsetof(tecton_plugin_metadata, required_features), offsetof(tecton_plugin_metadata, optional_features))

#define TECTON_ABI_FP_DESCRIPTOR(hash) \
  TECTON_ABI_FP_10((hash), sizeof(tecton_plugin_descriptor), offsetof(tecton_plugin_descriptor, struct_size), offsetof(tecton_plugin_descriptor, descriptor_version), offsetof(tecton_plugin_descriptor, abi_fingerprint), offsetof(tecton_plugin_descriptor, metadata), offsetof(tecton_plugin_descriptor, on_load), offsetof(tecton_plugin_descriptor, on_start), offsetof(tecton_plugin_descriptor, on_shutdown), offsetof(tecton_plugin_descriptor, on_unload), offsetof(tecton_plugin_descriptor, on_ready))

#define TECTON_ABI_FP_CONTEXT(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_plugin_context), offsetof(tecton_plugin_context, struct_size), offsetof(tecton_plugin_context, plugin_id), offsetof(tecton_plugin_context, host), offsetof(tecton_plugin_context, engine), offsetof(tecton_plugin_context, reserved))

#define TECTON_ABI_FP_ALLOCATOR(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_allocator), offsetof(tecton_allocator, userdata), offsetof(tecton_allocator, alloc), offsetof(tecton_allocator, free), offsetof(tecton_allocator, realloc), offsetof(tecton_allocator, alloc_zeroed))

#define TECTON_ABI_FP_HOST_API(hash) \
  TECTON_ABI_FP_14((hash), sizeof(tecton_host_api), offsetof(tecton_host_api, struct_size), offsetof(tecton_host_api, abi_major), offsetof(tecton_host_api, abi_minor), offsetof(tecton_host_api, plugin_id), offsetof(tecton_host_api, userdata), offsetof(tecton_host_api, allocator), offsetof(tecton_host_api, log), offsetof(tecton_host_api, event_subscribe), offsetof(tecton_host_api, event_unsubscribe), offsetof(tecton_host_api, emit_custom), offsetof(tecton_host_api, get_interface), offsetof(tecton_host_api, every), offsetof(tecton_host_api, features))

#define TECTON_ABI_FP_INTERFACE_HEADER(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_interface_header), offsetof(tecton_interface_header, struct_size), offsetof(tecton_interface_header, major), offsetof(tecton_interface_header, minor), offsetof(tecton_interface_header, interface_id), offsetof(tecton_interface_header, reserved), offsetof(tecton_interface_header, features))

#define TECTON_ABI_FP_EVENT_VIEW(hash) \
  TECTON_ABI_FP_8((hash), sizeof(tecton_event_view), offsetof(tecton_event_view, data), offsetof(tecton_event_view, data_size), offsetof(tecton_event_view, result), offsetof(tecton_event_view, schema), offsetof(tecton_event_view, event_id), offsetof(tecton_event_view, phase), offsetof(tecton_event_view, flags))

#define TECTON_ABI_FP_SERVER_TICK_EVENT(hash) \
  TECTON_ABI_FP_2((hash), sizeof(tecton_server_tick_event), offsetof(tecton_server_tick_event, tick))

#define TECTON_ABI_FP_PLAYER_EVENT(hash) \
  TECTON_ABI_FP_2((hash), sizeof(tecton_player_event), offsetof(tecton_player_event, handle))

#define TECTON_ABI_FP_PLAYER_JOIN_EVENT(hash) \
  TECTON_ABI_FP_3((hash), sizeof(tecton_player_join_event), offsetof(tecton_player_join_event, handle), offsetof(tecton_player_join_event, runtime_id))

#define TECTON_ABI_FP_PLAYER_REF_EVENT(hash) \
  TECTON_ABI_FP_3((hash), sizeof(tecton_player_ref_event), offsetof(tecton_player_ref_event, handle), offsetof(tecton_player_ref_event, runtime_id))

#define TECTON_ABI_FP_PLAYER_CHAT_EVENT(hash) \
  TECTON_ABI_FP_5((hash), sizeof(tecton_player_chat_event), offsetof(tecton_player_chat_event, runtime_id), offsetof(tecton_player_chat_event, message), offsetof(tecton_player_chat_event, flags), offsetof(tecton_player_chat_event, reserved))

#define TECTON_ABI_FP_ITEM_USE_EVENT(hash) \
  TECTON_ABI_FP_5((hash), sizeof(tecton_item_use_event), offsetof(tecton_item_use_event, runtime_id), offsetof(tecton_item_use_event, identifier), offsetof(tecton_item_use_event, flags), offsetof(tecton_item_use_event, reserved))

#define TECTON_ABI_FP_PLAYER_MOVE_EVENT(hash) \
  TECTON_ABI_FP_10((hash), sizeof(tecton_player_move_event), offsetof(tecton_player_move_event, runtime_id), offsetof(tecton_player_move_event, from_x), offsetof(tecton_player_move_event, from_y), offsetof(tecton_player_move_event, from_z), offsetof(tecton_player_move_event, to_x), offsetof(tecton_player_move_event, to_y), offsetof(tecton_player_move_event, to_z), offsetof(tecton_player_move_event, on_ground), offsetof(tecton_player_move_event, reserved))

#define TECTON_ABI_FP_DAMAGE_EVENT(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_damage_event), offsetof(tecton_damage_event, victim_runtime), offsetof(tecton_damage_event, attacker_runtime), offsetof(tecton_damage_event, amount), offsetof(tecton_damage_event, cause), offsetof(tecton_damage_event, reserved))

#define TECTON_ABI_FP_BLOCK_PLACE_EVENT(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_block_place_event), offsetof(tecton_block_place_event, runtime_id), offsetof(tecton_block_place_event, x), offsetof(tecton_block_place_event, y), offsetof(tecton_block_place_event, z), offsetof(tecton_block_place_event, network_id), offsetof(tecton_block_place_event, reserved))

#define TECTON_ABI_FP_BLOCK_BREAK_EVENT(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_block_break_event), offsetof(tecton_block_break_event, runtime_id), offsetof(tecton_block_break_event, x), offsetof(tecton_block_break_event, y), offsetof(tecton_block_break_event, z), offsetof(tecton_block_break_event, network_id), offsetof(tecton_block_break_event, reserved))

#define TECTON_ABI_FP_INVENTORY_EVENT(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_inventory_event), offsetof(tecton_inventory_event, handle), offsetof(tecton_inventory_event, container_id), offsetof(tecton_inventory_event, reserved))

#define TECTON_ABI_FP_INVENTORY_CLICK_EVENT(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_inventory_click_event), offsetof(tecton_inventory_click_event, handle), offsetof(tecton_inventory_click_event, slot), offsetof(tecton_inventory_click_event, button), offsetof(tecton_inventory_click_event, reserved), offsetof(tecton_inventory_click_event, reserved2))

#define TECTON_ABI_FP_TRANSACTION_EVENT(hash) \
  TECTON_ABI_FP_5((hash), sizeof(tecton_transaction_event), offsetof(tecton_transaction_event, handle), offsetof(tecton_transaction_event, transaction_id), offsetof(tecton_transaction_event, committed), offsetof(tecton_transaction_event, reserved))

#define TECTON_ABI_FP_ENTITY_COMBUST_EVENT(hash) \
  TECTON_ABI_FP_5((hash), sizeof(tecton_entity_combust_event), offsetof(tecton_entity_combust_event, runtime_id), offsetof(tecton_entity_combust_event, instigator_runtime), offsetof(tecton_entity_combust_event, duration), offsetof(tecton_entity_combust_event, source))

#define TECTON_ABI_FP_ENCHANT_EVENT(hash) \
  TECTON_ABI_FP_8((hash), sizeof(tecton_enchant_event), offsetof(tecton_enchant_event, item_handle), offsetof(tecton_enchant_event, actor_runtime), offsetof(tecton_enchant_event, enchantment_id), offsetof(tecton_enchant_event, previous_level), offsetof(tecton_enchant_event, level), offsetof(tecton_enchant_event, source), offsetof(tecton_enchant_event, reserved))

#define TECTON_ABI_FP_ENTITY_SPAWN_EVENT(hash) \
  TECTON_ABI_FP_3((hash), sizeof(tecton_entity_spawn_event), offsetof(tecton_entity_spawn_event, runtime_id), offsetof(tecton_entity_spawn_event, reserved))

#define TECTON_ABI_FP_ENTITY_DESPAWN_EVENT(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_entity_despawn_event), offsetof(tecton_entity_despawn_event, runtime_id), offsetof(tecton_entity_despawn_event, cause), offsetof(tecton_entity_despawn_event, reserved))

#define TECTON_ABI_FP_ENTITY_DAMAGE_EVENT(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_entity_damage_event), offsetof(tecton_entity_damage_event, target_runtime), offsetof(tecton_entity_damage_event, source_runtime), offsetof(tecton_entity_damage_event, amount), offsetof(tecton_entity_damage_event, cause), offsetof(tecton_entity_damage_event, reserved))

#define TECTON_ABI_FP_ENTITY_DEATH_EVENT(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_entity_death_event), offsetof(tecton_entity_death_event, runtime_id), offsetof(tecton_entity_death_event, killer_runtime), offsetof(tecton_entity_death_event, x), offsetof(tecton_entity_death_event, y), offsetof(tecton_entity_death_event, z), offsetof(tecton_entity_death_event, reserved))

#define TECTON_ABI_FP_ENTITY_INTERACT_EVENT(hash) \
  TECTON_ABI_FP_5((hash), sizeof(tecton_entity_interact_event), offsetof(tecton_entity_interact_event, target_runtime), offsetof(tecton_entity_interact_event, player_runtime), offsetof(tecton_entity_interact_event, action), offsetof(tecton_entity_interact_event, reserved))

#define TECTON_ABI_FP_SNAPSHOT_HEADER(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_snapshot_header), offsetof(tecton_snapshot_header, struct_size), offsetof(tecton_snapshot_header, version), offsetof(tecton_snapshot_header, reserved))

#define TECTON_ABI_FP_WORLD_SNAPSHOT(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_world_snapshot), offsetof(tecton_world_snapshot, header), offsetof(tecton_world_snapshot, handle), offsetof(tecton_world_snapshot, name))

#define TECTON_ABI_FP_PLAYER_SNAPSHOT(hash) \
  TECTON_ABI_FP_15((hash), sizeof(tecton_player_snapshot), offsetof(tecton_player_snapshot, header), offsetof(tecton_player_snapshot, handle), offsetof(tecton_player_snapshot, runtime_id), offsetof(tecton_player_snapshot, name), offsetof(tecton_player_snapshot, uuid), offsetof(tecton_player_snapshot, world), offsetof(tecton_player_snapshot, dimension), offsetof(tecton_player_snapshot, x), offsetof(tecton_player_snapshot, y), offsetof(tecton_player_snapshot, z), offsetof(tecton_player_snapshot, yaw), offsetof(tecton_player_snapshot, pitch), offsetof(tecton_player_snapshot, gamemode), offsetof(tecton_player_snapshot, spawned))

#define TECTON_ABI_FP_ENTITY_SNAPSHOT(hash) \
  TECTON_ABI_FP_10((hash), sizeof(tecton_entity_snapshot), offsetof(tecton_entity_snapshot, header), offsetof(tecton_entity_snapshot, handle), offsetof(tecton_entity_snapshot, runtime_id), offsetof(tecton_entity_snapshot, type), offsetof(tecton_entity_snapshot, world), offsetof(tecton_entity_snapshot, dimension), offsetof(tecton_entity_snapshot, x), offsetof(tecton_entity_snapshot, y), offsetof(tecton_entity_snapshot, z))

#define TECTON_ABI_FP_ITEM_SNAPSHOT(hash) \
  TECTON_ABI_FP_8((hash), sizeof(tecton_item_snapshot), offsetof(tecton_item_snapshot, header), offsetof(tecton_item_snapshot, handle), offsetof(tecton_item_snapshot, network_id), offsetof(tecton_item_snapshot, max_stack_size), offsetof(tecton_item_snapshot, stackable), offsetof(tecton_item_snapshot, reserved), offsetof(tecton_item_snapshot, identifier))

#define TECTON_ABI_FP_BLOCK_SNAPSHOT(hash) \
  TECTON_ABI_FP_9((hash), sizeof(tecton_block_snapshot), offsetof(tecton_block_snapshot, header), offsetof(tecton_block_snapshot, world), offsetof(tecton_block_snapshot, dimension), offsetof(tecton_block_snapshot, x), offsetof(tecton_block_snapshot, y), offsetof(tecton_block_snapshot, z), offsetof(tecton_block_snapshot, network_id), offsetof(tecton_block_snapshot, identifier))

#define TECTON_ABI_FP_INVENTORY_ITEM_SNAPSHOT(hash) \
  TECTON_ABI_FP_9((hash), sizeof(tecton_inventory_item_snapshot), offsetof(tecton_inventory_item_snapshot, header), offsetof(tecton_inventory_item_snapshot, present), offsetof(tecton_inventory_item_snapshot, reserved), offsetof(tecton_inventory_item_snapshot, count), offsetof(tecton_inventory_item_snapshot, reserved_count), offsetof(tecton_inventory_item_snapshot, network_id), offsetof(tecton_inventory_item_snapshot, metadata), offsetof(tecton_inventory_item_snapshot, identifier))

#define TECTON_ABI_FP_WORLD_API(hash) \
  TECTON_ABI_FP_8((hash), sizeof(tecton_world_api), offsetof(tecton_world_api, header), offsetof(tecton_world_api, find), offsetof(tecton_world_api, get_snapshot), offsetof(tecton_world_api, set_block), offsetof(tecton_world_api, get_block_state), offsetof(tecton_world_api, set_block_state), offsetof(tecton_world_api, for_each_in_box))

#define TECTON_ABI_FP_PLAYERS_API(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_players_api), offsetof(tecton_players_api, header), offsetof(tecton_players_api, count), offsetof(tecton_players_api, get_snapshot), offsetof(tecton_players_api, get_by_index), offsetof(tecton_players_api, get_by_runtime), offsetof(tecton_players_api, for_each))

#define TECTON_ABI_FP_ENTITIES_API(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_entities_api), offsetof(tecton_entities_api, header), offsetof(tecton_entities_api, count), offsetof(tecton_entities_api, get_snapshot), offsetof(tecton_entities_api, get_by_index), offsetof(tecton_entities_api, get_by_runtime), offsetof(tecton_entities_api, for_each))

#define TECTON_ABI_FP_ITEMS_API(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_items_api), offsetof(tecton_items_api, header), offsetof(tecton_items_api, count), offsetof(tecton_items_api, get_snapshot), offsetof(tecton_items_api, get_by_index), offsetof(tecton_items_api, get_by_network_id), offsetof(tecton_items_api, for_each))

#define TECTON_ABI_FP_BLOCKS_API(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_blocks_api), offsetof(tecton_blocks_api, header), offsetof(tecton_blocks_api, get_snapshot), offsetof(tecton_blocks_api, resolve_name))

#define TECTON_ABI_FP_INVENTORIES_API(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_inventories_api), offsetof(tecton_inventories_api, header), offsetof(tecton_inventories_api, get_size), offsetof(tecton_inventories_api, get_item))

#define TECTON_ABI_FP_CORE_API(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_core_api), offsetof(tecton_core_api, header), offsetof(tecton_core_api, get_tick), offsetof(tecton_core_api, get_state))

#define TECTON_ABI_FP_SCHEDULER_API(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_scheduler_api), offsetof(tecton_scheduler_api, header), offsetof(tecton_scheduler_api, after), offsetof(tecton_scheduler_api, every), offsetof(tecton_scheduler_api, cancel), offsetof(tecton_scheduler_api, cancel_owner))

#define TECTON_ABI_FP_NETWORK_API(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_network_api), offsetof(tecton_network_api, header), offsetof(tecton_network_api, send), offsetof(tecton_network_api, broadcast))

#define TECTON_ABI_FP_LOGGING_API(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_logging_api), offsetof(tecton_logging_api, header), offsetof(tecton_logging_api, log), offsetof(tecton_logging_api, is_enabled), offsetof(tecton_logging_api, set_level), offsetof(tecton_logging_api, set_scope))

#define TECTON_ABI_FP_EVENTS_API(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_events_api), offsetof(tecton_events_api, header), offsetof(tecton_events_api, subscribe), offsetof(tecton_events_api, unsubscribe), offsetof(tecton_events_api, emit), offsetof(tecton_events_api, emit_immediate), offsetof(tecton_events_api, schema_of))

#define TECTON_ABI_FP_REGISTRY_VIEW(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_registry_view), offsetof(tecton_registry_view, data), offsetof(tecton_registry_view, count), offsetof(tecton_registry_view, stride), offsetof(tecton_registry_view, element_version), offsetof(tecton_registry_view, reserved))

#define TECTON_ABI_FP_BLOCK_STATE_ENTRY(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_block_state_entry), offsetof(tecton_block_state_entry, network_id), offsetof(tecton_block_state_entry, reserved), offsetof(tecton_block_state_entry, identifier))

#define TECTON_ABI_FP_ITEM_ENTRY(hash) \
  TECTON_ABI_FP_6((hash), sizeof(tecton_item_entry), offsetof(tecton_item_entry, network_id), offsetof(tecton_item_entry, max_stack_size), offsetof(tecton_item_entry, stackable), offsetof(tecton_item_entry, reserved), offsetof(tecton_item_entry, identifier))

#define TECTON_ABI_FP_ENTITY_TYPE_ENTRY(hash) \
  TECTON_ABI_FP_4((hash), sizeof(tecton_entity_type_entry), offsetof(tecton_entity_type_entry, network_id), offsetof(tecton_entity_type_entry, reserved), offsetof(tecton_entity_type_entry, identifier))

#define TECTON_ABI_FP_REGISTRIES_API(hash) \
  TECTON_ABI_FP_5((hash), sizeof(tecton_registries_api), offsetof(tecton_registries_api, header), offsetof(tecton_registries_api, block_states), offsetof(tecton_registries_api, items), offsetof(tecton_registries_api, entity_types))

#define TECTON_ABI_FP_COMMAND_DESC(hash) \
  TECTON_ABI_FP_11((hash), sizeof(tecton_command_desc), offsetof(tecton_command_desc, struct_size), offsetof(tecton_command_desc, flags), offsetof(tecton_command_desc, name), offsetof(tecton_command_desc, description), offsetof(tecton_command_desc, permission), offsetof(tecton_command_desc, aliases), offsetof(tecton_command_desc, alias_count), offsetof(tecton_command_desc, reserved), offsetof(tecton_command_desc, handler), offsetof(tecton_command_desc, userdata))

#define TECTON_ABI_FP_COMMAND_CALL(hash) \
  TECTON_ABI_FP_8((hash), sizeof(tecton_command_call), offsetof(tecton_command_call, struct_size), offsetof(tecton_command_call, argc), offsetof(tecton_command_call, argv), offsetof(tecton_command_call, raw_line), offsetof(tecton_command_call, player), offsetof(tecton_command_call, world), offsetof(tecton_command_call, userdata))

#define TECTON_ABI_FP_BLOCK_BOX(hash) \
  TECTON_ABI_FP_7((hash), sizeof(tecton_block_box), offsetof(tecton_block_box, min_x), offsetof(tecton_block_box, min_y), offsetof(tecton_block_box, min_z), offsetof(tecton_block_box, max_x), offsetof(tecton_block_box, max_y), offsetof(tecton_block_box, max_z))

#define TECTON_ABI_FP_COMMANDS_API(hash) \
  TECTON_ABI_FP_5((hash), sizeof(tecton_commands_api), offsetof(tecton_commands_api, header), offsetof(tecton_commands_api, register_command), offsetof(tecton_commands_api, unregister), offsetof(tecton_commands_api, mark_dirty))

#define TECTON_ABI_FP_ITEM(tag, value) TECTON_ABI_FP_VALUE((TECTON_ABI_FP_SEED ^ UINT64_C(tag)), (value))

#define TECTON_ABI_FP_CONSTANTS \
  (TECTON_ABI_FP_ITEM(1001, TECTON_PLUGIN_ABI_MAJOR)) ^ \
  (TECTON_ABI_FP_ITEM(1002, TECTON_PLUGIN_ABI_MINOR)) ^ \
  (TECTON_ABI_FP_ITEM(1003, TECTON_PLUGIN_DESCRIPTOR_VERSION)) ^ \
  (TECTON_ABI_FP_ITEM(1004, TECTON_PLUGIN_STATUS_OK)) ^ \
  (TECTON_ABI_FP_ITEM(1005, TECTON_PLUGIN_STATUS_ABI_MAJOR)) ^ \
  (TECTON_ABI_FP_ITEM(1006, TECTON_PLUGIN_STATUS_ABI_MINOR)) ^ \
  (TECTON_ABI_FP_ITEM(1007, TECTON_PLUGIN_STATUS_HOST_TOO_OLD)) ^ \
  (TECTON_ABI_FP_ITEM(1008, TECTON_PLUGIN_STATUS_BUILD_TARGET)) ^ \
  (TECTON_ABI_FP_ITEM(1009, TECTON_LOG_TRACE)) ^ \
  (TECTON_ABI_FP_ITEM(1010, TECTON_LOG_DEBUG)) ^ \
  (TECTON_ABI_FP_ITEM(1011, TECTON_LOG_INFO)) ^ \
  (TECTON_ABI_FP_ITEM(1012, TECTON_LOG_WARN)) ^ \
  (TECTON_ABI_FP_ITEM(1013, TECTON_LOG_ERROR)) ^ \
  (TECTON_ABI_FP_ITEM(1014, TECTON_SHUTDOWN_NORMAL)) ^ \
  (TECTON_ABI_FP_ITEM(1015, TECTON_SHUTDOWN_FAULT)) ^ \
  (TECTON_ABI_FP_ITEM(1016, TECTON_SHUTDOWN_RELOAD)) ^ \
  (TECTON_ABI_FP_ITEM(1017, TECTON_SHUTDOWN_SERVER_EXIT)) ^ \
  (TECTON_ABI_FP_ITEM(1018, TECTON_EVENT_PHASE_PRE)) ^ \
  (TECTON_ABI_FP_ITEM(1019, TECTON_EVENT_PHASE_COMMIT)) ^ \
  (TECTON_ABI_FP_ITEM(1020, TECTON_EVENT_PHASE_POST)) ^ \
  (TECTON_ABI_FP_ITEM(1021, TECTON_FEATURE_EVENTS)) ^ \
  (TECTON_ABI_FP_ITEM(1022, TECTON_FEATURE_LOGGING)) ^ \
  (TECTON_ABI_FP_ITEM(1023, TECTON_FEATURE_ALLOCATOR)) ^ \
  (TECTON_ABI_FP_ITEM(1024, TECTON_FEATURE_SCHEDULER)) ^ \
  (TECTON_ABI_FP_ITEM(1025, TECTON_FEATURE_WORLD)) ^ \
  (TECTON_ABI_FP_ITEM(1026, TECTON_FEATURE_PLAYERS)) ^ \
  (TECTON_ABI_FP_ITEM(1027, TECTON_FEATURE_ENTITIES)) ^ \
  (TECTON_ABI_FP_ITEM(1028, TECTON_FEATURE_ITEMS)) ^ \
  (TECTON_ABI_FP_ITEM(1029, TECTON_FEATURE_BLOCKS)) ^ \
  (TECTON_ABI_FP_ITEM(1030, TECTON_FEATURE_INVENTORIES)) ^ \
  (TECTON_ABI_FP_ITEM(1031, TECTON_FEATURE_REGISTRIES)) ^ \
  (TECTON_ABI_FP_ITEM(1032, TECTON_FEATURE_NETWORK)) ^ \
  (TECTON_ABI_FP_ITEM(1033, TECTON_FEATURE_COMMANDS)) ^ \
  (TECTON_ABI_FP_ITEM(1096, TECTON_FEATURE_CUSTOM_EVENTS)) ^ \
  (TECTON_ABI_FP_ITEM(1097, TECTON_FEATURE_TRAITS)) ^ \
  (TECTON_ABI_FP_ITEM(1098, TECTON_FEATURE_HOT_UNLOAD)) ^ \
  (TECTON_ABI_FP_ITEM(1099, TECTON_BLOCK_APPLY_TRAITS)) ^ \
  (TECTON_ABI_FP_ITEM(1100, TECTON_BLOCK_UPDATE_CLIENTS)) ^ \
  (TECTON_ABI_FP_ITEM(1101, TECTON_BLOCK_SILENT)) ^ \
  (TECTON_ABI_FP_ITEM(1034, TECTON_EVENT_SERVER_START)) ^ \
  (TECTON_ABI_FP_ITEM(1035, TECTON_EVENT_SERVER_SHUTDOWN)) ^ \
  (TECTON_ABI_FP_ITEM(1036, TECTON_EVENT_SERVER_TICK)) ^ \
  (TECTON_ABI_FP_ITEM(1037, TECTON_EVENT_PLAYER_JOIN)) ^ \
  (TECTON_ABI_FP_ITEM(1038, TECTON_EVENT_PLAYER_DISCONNECT)) ^ \
  (TECTON_ABI_FP_ITEM(1039, TECTON_EVENT_PLAYER_CHAT)) ^ \
  (TECTON_ABI_FP_ITEM(1040, TECTON_EVENT_ITEM_USE)) ^ \
  (TECTON_ABI_FP_ITEM(1041, TECTON_EVENT_PLAYER_MOVE)) ^ \
  (TECTON_ABI_FP_ITEM(1042, TECTON_EVENT_DAMAGE)) ^ \
  (TECTON_ABI_FP_ITEM(1043, TECTON_EVENT_BLOCK_PLACE)) ^ \
  (TECTON_ABI_FP_ITEM(1044, TECTON_EVENT_BLOCK_BREAK)) ^ \
  (TECTON_ABI_FP_ITEM(1045, TECTON_EVENT_INVENTORY_OPEN)) ^ \
  (TECTON_ABI_FP_ITEM(1046, TECTON_EVENT_INVENTORY_CLICK)) ^ \
  (TECTON_ABI_FP_ITEM(1047, TECTON_EVENT_INVENTORY_CLOSE)) ^ \
  (TECTON_ABI_FP_ITEM(1048, TECTON_EVENT_TRANSACTION_PREPARE)) ^ \
  (TECTON_ABI_FP_ITEM(1049, TECTON_EVENT_TRANSACTION_COMMIT)) ^ \
  (TECTON_ABI_FP_ITEM(1050, TECTON_EVENT_TRANSACTION_ABORT)) ^ \
  (TECTON_ABI_FP_ITEM(1051, TECTON_EVENT_FLAG_CANCELABLE)) ^ \
  (TECTON_ABI_FP_ITEM(1052, TECTON_EVENT_FLAG_MUTABLE)) ^ \
  (TECTON_ABI_FP_ITEM(1053, TECTON_EVENT_FLAG_CALLBACK_ONLY)) ^ \
  (TECTON_ABI_FP_ITEM(1054, TECTON_EVENT_FLAG_BORROWED)) ^ \
  (TECTON_ABI_FP_ITEM(1055, TECTON_RESULT_OK)) ^ \
  (TECTON_ABI_FP_ITEM(1056, TECTON_RESULT_INVALID_ARGUMENT)) ^ \
  (TECTON_ABI_FP_ITEM(1057, TECTON_RESULT_UNSUPPORTED)) ^ \
  (TECTON_ABI_FP_ITEM(1058, TECTON_RESULT_NOT_FOUND)) ^ \
  (TECTON_ABI_FP_ITEM(1059, TECTON_RESULT_WRONG_THREAD)) ^ \
  (TECTON_ABI_FP_ITEM(1060, TECTON_RESULT_INVALID_HANDLE)) ^ \
  (TECTON_ABI_FP_ITEM(1061, TECTON_RESULT_BUSY)) ^ \
  (TECTON_ABI_FP_ITEM(1062, TECTON_RESULT_CONFLICT)) ^ \
  (TECTON_ABI_FP_ITEM(1063, TECTON_RESULT_OUT_OF_MEMORY)) ^ \
  (TECTON_ABI_FP_ITEM(1064, TECTON_RESULT_VERSION)) ^ \
  (TECTON_ABI_FP_ITEM(1065, TECTON_RESULT_UNLOADED)) ^ \
  (TECTON_ABI_FP_ITEM(1066, TECTON_RESULT_DENIED)) ^ \
  (TECTON_ABI_FP_ITEM(1067, TECTON_RESULT_LIMIT)) ^ \
  (TECTON_ABI_FP_ITEM(1102, TECTON_LOAD_OK)) ^ \
  (TECTON_ABI_FP_ITEM(1103, TECTON_LOAD_DLOPEN)) ^ \
  (TECTON_ABI_FP_ITEM(1104, TECTON_LOAD_SYMBOL_MISSING)) ^ \
  (TECTON_ABI_FP_ITEM(1105, TECTON_LOAD_LEGACY_ABI)) ^ \
  (TECTON_ABI_FP_ITEM(1106, TECTON_LOAD_ABI_MAJOR)) ^ \
  (TECTON_ABI_FP_ITEM(1107, TECTON_LOAD_ABI_MINOR)) ^ \
  (TECTON_ABI_FP_ITEM(1108, TECTON_LOAD_FINGERPRINT)) ^ \
  (TECTON_ABI_FP_ITEM(1109, TECTON_LOAD_DESCRIPTOR)) ^ \
  (TECTON_ABI_FP_ITEM(1110, TECTON_LOAD_METADATA)) ^ \
  (TECTON_ABI_FP_ITEM(1111, TECTON_LOAD_DUPLICATE_NAME)) ^ \
  (TECTON_ABI_FP_ITEM(1112, TECTON_LOAD_REQUIRED_FEATURE)) ^ \
  (TECTON_ABI_FP_ITEM(1113, TECTON_LOAD_MISSING_CALLBACK)) ^ \
  (TECTON_ABI_FP_ITEM(1114, TECTON_LOAD_CALLBACK_FAILED)) ^ \
  (TECTON_ABI_FP_ITEM(1115, TECTON_LOAD_OUT_OF_MEMORY)) ^ \
  (TECTON_ABI_FP_ITEM(1068, TECTON_PACKET_PRIORITY_NORMAL)) ^ \
  (TECTON_ABI_FP_ITEM(1069, TECTON_PACKET_PRIORITY_IMMEDIATE)) ^ \
  (TECTON_ABI_FP_ITEM(1070, TECTON_EVENT_CUSTOM_BASE)) ^ \
  (TECTON_ABI_FP_ITEM(1071, TECTON_INTERFACE_CORE)) ^ \
  (TECTON_ABI_FP_ITEM(1072, TECTON_INTERFACE_LOGGING)) ^ \
  (TECTON_ABI_FP_ITEM(1073, TECTON_INTERFACE_EVENTS)) ^ \
  (TECTON_ABI_FP_ITEM(1074, TECTON_INTERFACE_SCHEDULER)) ^ \
  (TECTON_ABI_FP_ITEM(1075, TECTON_INTERFACE_WORLD)) ^ \
  (TECTON_ABI_FP_ITEM(1076, TECTON_INTERFACE_PLAYERS)) ^ \
  (TECTON_ABI_FP_ITEM(1077, TECTON_INTERFACE_ENTITIES)) ^ \
  (TECTON_ABI_FP_ITEM(1078, TECTON_INTERFACE_ITEMS)) ^ \
  (TECTON_ABI_FP_ITEM(1079, TECTON_INTERFACE_BLOCKS)) ^ \
  (TECTON_ABI_FP_ITEM(1080, TECTON_INTERFACE_INVENTORIES)) ^ \
  (TECTON_ABI_FP_ITEM(1081, TECTON_INTERFACE_REGISTRIES)) ^ \
  (TECTON_ABI_FP_ITEM(1082, TECTON_INTERFACE_NETWORK)) ^ \
  (TECTON_ABI_FP_ITEM(1083, TECTON_INTERFACE_COMMANDS)) ^ \
  (TECTON_ABI_FP_ITEM(1086, TECTON_CUSTOM_PAYLOAD_MAX)) ^ \
  (TECTON_ABI_FP_ITEM(1087, TECTON_MAX_CUSTOM_EVENTS)) ^ \
  (TECTON_ABI_FP_ITEM(1088, TECTON_EVENT_ENTITY_COMBUST)) ^ \
  (TECTON_ABI_FP_ITEM(1089, TECTON_EVENT_ENCHANTMENT_APPLY)) ^ \
  (TECTON_ABI_FP_ITEM(1090, TECTON_EVENT_ENCHANTMENT_REMOVE)) ^ \
  (TECTON_ABI_FP_ITEM(1091, TECTON_EVENT_ENTITY_SPAWN)) ^ \
  (TECTON_ABI_FP_ITEM(1092, TECTON_EVENT_ENTITY_DESPAWN)) ^ \
  (TECTON_ABI_FP_ITEM(1093, TECTON_EVENT_ENTITY_DAMAGE)) ^ \
  (TECTON_ABI_FP_ITEM(1094, TECTON_EVENT_ENTITY_DEATH)) ^ \
  (TECTON_ABI_FP_ITEM(1095, TECTON_EVENT_ENTITY_INTERACT))

/* Members use FNV-1a and are XOR-combined: one left-to-right chain exceeds C
   compilers' bracket nesting limit. */
#define TECTON_ABI_FINGERPRINT \
  ((TECTON_ABI_FP_STRING_VIEW(TECTON_ABI_FP_SEED ^ UINT64_C(1))) ^ \
  (TECTON_ABI_FP_API_VERSION(TECTON_ABI_FP_SEED ^ UINT64_C(2))) ^ \
  (TECTON_ABI_FP_HOST_QUERY(TECTON_ABI_FP_SEED ^ UINT64_C(3))) ^ \
  (TECTON_ABI_FP_PLUGIN_INFO(TECTON_ABI_FP_SEED ^ UINT64_C(4))) ^ \
  (TECTON_ABI_FP_METADATA(TECTON_ABI_FP_SEED ^ UINT64_C(5))) ^ \
  (TECTON_ABI_FP_DESCRIPTOR(TECTON_ABI_FP_SEED ^ UINT64_C(6))) ^ \
  (TECTON_ABI_FP_CONTEXT(TECTON_ABI_FP_SEED ^ UINT64_C(7))) ^ \
  (TECTON_ABI_FP_ALLOCATOR(TECTON_ABI_FP_SEED ^ UINT64_C(8))) ^ \
  (TECTON_ABI_FP_INTERFACE_HEADER(TECTON_ABI_FP_SEED ^ UINT64_C(9))) ^ \
  (TECTON_ABI_FP_EVENT_VIEW(TECTON_ABI_FP_SEED ^ UINT64_C(10))) ^ \
  (TECTON_ABI_FP_SERVER_TICK_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(28))) ^ \
  (TECTON_ABI_FP_PLAYER_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(29))) ^ \
  (TECTON_ABI_FP_PLAYER_JOIN_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(39))) ^ \
  (TECTON_ABI_FP_PLAYER_REF_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(40))) ^ \
  (TECTON_ABI_FP_PLAYER_CHAT_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(41))) ^ \
  (TECTON_ABI_FP_ITEM_USE_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(42))) ^ \
  (TECTON_ABI_FP_PLAYER_MOVE_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(43))) ^ \
  (TECTON_ABI_FP_DAMAGE_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(44))) ^ \
  (TECTON_ABI_FP_BLOCK_PLACE_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(45))) ^ \
  (TECTON_ABI_FP_BLOCK_BREAK_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(46))) ^ \
  (TECTON_ABI_FP_INVENTORY_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(47))) ^ \
  (TECTON_ABI_FP_INVENTORY_CLICK_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(48))) ^ \
  (TECTON_ABI_FP_TRANSACTION_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(49))) ^ \
  (TECTON_ABI_FP_ENTITY_COMBUST_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(50))) ^ \
  (TECTON_ABI_FP_ENCHANT_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(51))) ^ \
  (TECTON_ABI_FP_ENTITY_SPAWN_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(52))) ^ \
  (TECTON_ABI_FP_ENTITY_DESPAWN_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(53))) ^ \
  (TECTON_ABI_FP_ENTITY_DAMAGE_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(54))) ^ \
  (TECTON_ABI_FP_ENTITY_DEATH_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(55))) ^ \
  (TECTON_ABI_FP_ENTITY_INTERACT_EVENT(TECTON_ABI_FP_SEED ^ UINT64_C(56))) ^ \
  (TECTON_ABI_FP_SNAPSHOT_HEADER(TECTON_ABI_FP_SEED ^ UINT64_C(11))) ^ \
  (TECTON_ABI_FP_WORLD_SNAPSHOT(TECTON_ABI_FP_SEED ^ UINT64_C(12))) ^ \
  (TECTON_ABI_FP_PLAYER_SNAPSHOT(TECTON_ABI_FP_SEED ^ UINT64_C(13))) ^ \
  (TECTON_ABI_FP_ENTITY_SNAPSHOT(TECTON_ABI_FP_SEED ^ UINT64_C(14))) ^ \
  (TECTON_ABI_FP_ITEM_SNAPSHOT(TECTON_ABI_FP_SEED ^ UINT64_C(15))) ^ \
  (TECTON_ABI_FP_BLOCK_SNAPSHOT(TECTON_ABI_FP_SEED ^ UINT64_C(16))) ^ \
  (TECTON_ABI_FP_INVENTORY_ITEM_SNAPSHOT(TECTON_ABI_FP_SEED ^ UINT64_C(17))) ^ \
  (TECTON_ABI_FP_WORLD_API(TECTON_ABI_FP_SEED ^ UINT64_C(18))) ^ \
  (TECTON_ABI_FP_PLAYERS_API(TECTON_ABI_FP_SEED ^ UINT64_C(19))) ^ \
  (TECTON_ABI_FP_ENTITIES_API(TECTON_ABI_FP_SEED ^ UINT64_C(20))) ^ \
  (TECTON_ABI_FP_ITEMS_API(TECTON_ABI_FP_SEED ^ UINT64_C(21))) ^ \
  (TECTON_ABI_FP_BLOCKS_API(TECTON_ABI_FP_SEED ^ UINT64_C(22))) ^ \
  (TECTON_ABI_FP_INVENTORIES_API(TECTON_ABI_FP_SEED ^ UINT64_C(23))) ^ \
  (TECTON_ABI_FP_CORE_API(TECTON_ABI_FP_SEED ^ UINT64_C(24))) ^ \
  (TECTON_ABI_FP_SCHEDULER_API(TECTON_ABI_FP_SEED ^ UINT64_C(25))) ^ \
  (TECTON_ABI_FP_NETWORK_API(TECTON_ABI_FP_SEED ^ UINT64_C(26))) ^ \
  (TECTON_ABI_FP_HOST_API(TECTON_ABI_FP_SEED ^ UINT64_C(27))) ^ \
  (TECTON_ABI_FP_LOGGING_API(TECTON_ABI_FP_SEED ^ UINT64_C(30))) ^ \
  (TECTON_ABI_FP_EVENTS_API(TECTON_ABI_FP_SEED ^ UINT64_C(31))) ^ \
  (TECTON_ABI_FP_REGISTRY_VIEW(TECTON_ABI_FP_SEED ^ UINT64_C(32))) ^ \
  (TECTON_ABI_FP_BLOCK_STATE_ENTRY(TECTON_ABI_FP_SEED ^ UINT64_C(33))) ^ \
  (TECTON_ABI_FP_ITEM_ENTRY(TECTON_ABI_FP_SEED ^ UINT64_C(34))) ^ \
  (TECTON_ABI_FP_ENTITY_TYPE_ENTRY(TECTON_ABI_FP_SEED ^ UINT64_C(35))) ^ \
  (TECTON_ABI_FP_REGISTRIES_API(TECTON_ABI_FP_SEED ^ UINT64_C(36))) ^ \
  (TECTON_ABI_FP_COMMAND_DESC(TECTON_ABI_FP_SEED ^ UINT64_C(37))) ^ \
  (TECTON_ABI_FP_COMMANDS_API(TECTON_ABI_FP_SEED ^ UINT64_C(38))) ^ \
  (TECTON_ABI_FP_COMMAND_CALL(TECTON_ABI_FP_SEED ^ UINT64_C(57))) ^ \
  (TECTON_ABI_FP_BLOCK_BOX(TECTON_ABI_FP_SEED ^ UINT64_C(58))) ^ \
  (TECTON_ABI_FP_CONSTANTS))

#ifdef __cplusplus
}
#endif

#endif
