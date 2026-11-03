#include <tecton_plugin.h>

static const tecton_host_api *host;
static void *host_userdata;
static uint64_t subscription;
static uint64_t task;
static uint64_t item_handle;
static uint32_t lifecycle_mask;
static uint32_t shutdown_reason;

static void TECTON_PLUGIN_CALL on_tick(void *userdata,
                                      const tecton_event_view *event) {
  (void)userdata;
  (void)event;
}

static int32_t TECTON_PLUGIN_CALL on_task(void *userdata) {
  (void)userdata;
  return 0;
}

static int32_t TECTON_PLUGIN_CALL on_load(tecton_plugin_context *value) {
  if (value == 0 || value->host == 0)
    return 1;
  host = value->host;
  host_userdata = host->userdata;
  lifecycle_mask |= 1u;
  return 0;
}

static int32_t TECTON_PLUGIN_CALL on_start(tecton_plugin_context *value) {
  lifecycle_mask |= 2u;

  const tecton_items_api *items = 0;
  if (host->get_interface(host_userdata, TECTON_INTERFACE_ITEMS, 1, 0,
                          (const tecton_interface_header **)&items) ==
          TECTON_RESULT_OK &&
      items != 0) {
    size_t count = 0;
    if (items->count(host_userdata, &count) == TECTON_RESULT_OK && count > 0) {
      tecton_item_snapshot snapshot = {0};
      snapshot.header.struct_size = sizeof(snapshot);
      if (items->get_snapshot(host_userdata, 0, &snapshot, sizeof(snapshot)) ==
          TECTON_RESULT_OK) {
        item_handle = snapshot.handle;
      }
    }
  }

  const tecton_scheduler_api *scheduler = 0;
  if (host->get_interface(host_userdata, TECTON_INTERFACE_SCHEDULER, 1, 0,
                          (const tecton_interface_header **)&scheduler) ==
          TECTON_RESULT_OK &&
      scheduler != 0) {
    (void)scheduler->schedule(host_userdata, value->plugin_id, on_task, 0,
                              &task);
  }

  (void)host->event_subscribe(host_userdata, TECTON_EVENT_SERVER_TICK,
                              TECTON_EVENT_PHASE_PRE, 0, on_tick, 0,
                              &subscription);
  return 1;
}

static void TECTON_PLUGIN_CALL on_shutdown(tecton_plugin_context *value,
                                            uint32_t reason) {
  (void)value;
  lifecycle_mask |= 8u;
  shutdown_reason = reason;
  if (host != 0 && subscription != 0) {
    (void)host->event_unsubscribe(host_userdata, subscription);
    subscription = 0;
  }
}

static void TECTON_PLUGIN_CALL on_unload(tecton_plugin_context *value) {
  (void)value;
  lifecycle_mask |= 16u;
  host = 0;
  host_userdata = 0;
}

static const tecton_plugin_descriptor descriptor = {
    .struct_size = sizeof(tecton_plugin_descriptor),
    .descriptor_version = TECTON_PLUGIN_DESCRIPTOR_VERSION,
    .abi_fingerprint = TECTON_ABI_FINGERPRINT,
    .metadata =
        {
            .struct_size = sizeof(tecton_plugin_metadata),
            .plugin_flags = 0,
            .name = TECTON_STR("tecton-c-failure"),
            .version = TECTON_STR("2.0.0"),
            .description = TECTON_STR("Fails on_start after acquiring resources"),
            .api = {TECTON_PLUGIN_ABI_MAJOR, TECTON_PLUGIN_ABI_MINOR, 0, 0},
            .required_features = TECTON_FEATURE_EVENTS | TECTON_FEATURE_ITEMS |
                                 TECTON_FEATURE_SCHEDULER,
            .optional_features = 0,
        },
    .on_load = on_load,
    .on_start = on_start,
    .on_shutdown = on_shutdown,
    .on_unload = on_unload,
    .on_ready = 0,
};

TECTON_PLUGIN_EXPORT uint32_t TECTON_PLUGIN_CALL
tecton_failure_mask(void) {
  return lifecycle_mask;
}

TECTON_PLUGIN_EXPORT uint32_t TECTON_PLUGIN_CALL
tecton_failure_shutdown_reason(void) {
  return shutdown_reason;
}

TECTON_PLUGIN_EXPORT int32_t TECTON_PLUGIN_CALL
tecton_plugin_query(const tecton_host_query *query, tecton_plugin_info *info) {
  if (query == 0 || info == 0 || info->struct_size < sizeof(*info))
    return TECTON_RESULT_INVALID_ARGUMENT;
  info->descriptor = 0;
  info->diagnostic = TECTON_STR("");
  if (query->abi_major != TECTON_PLUGIN_ABI_MAJOR) {
    info->status = TECTON_PLUGIN_STATUS_ABI_MAJOR;
    return TECTON_RESULT_VERSION;
  }
  if (query->abi_fingerprint != TECTON_ABI_FINGERPRINT) {
    info->status = TECTON_PLUGIN_STATUS_ABI_MINOR;
    return TECTON_RESULT_VERSION;
  }
  info->status = TECTON_PLUGIN_STATUS_OK;
  info->abi_major = TECTON_PLUGIN_ABI_MAJOR;
  info->abi_minor = TECTON_PLUGIN_ABI_MINOR;
  info->abi_fingerprint = TECTON_ABI_FINGERPRINT;
  info->descriptor = &descriptor;
  (void)item_handle;
  return TECTON_RESULT_OK;
}
