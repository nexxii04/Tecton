#include <tecton_plugin.h>

static tecton_plugin_context *context;
static const tecton_host_api *host;
static void *host_userdata;
static uint64_t subscription;

static void TECTON_PLUGIN_CALL on_tick_event(void *userdata,
                                              const tecton_event_view *event) {
  (void)userdata;
  if (event->schema != TECTON_SCHEMA_SERVER_TICK)
    return;
  const tecton_server_tick_event *tick = event->data;
  if (tick->tick == 0)
    return;
  host->log(host_userdata, TECTON_LOG_INFO,
            TECTON_STR("C plugin observed server tick"));
}

static int32_t TECTON_PLUGIN_CALL on_load(tecton_plugin_context *value) {
  if (value == 0 || value->host == 0)
    return 1;
  context = value;
  host = value->host;
  host_userdata = host->userdata;
  return 0;
}

static int32_t TECTON_PLUGIN_CALL on_start(tecton_plugin_context *value) {
  (void)value;
  if (host->event_subscribe(host_userdata, TECTON_EVENT_SERVER_TICK,
                            TECTON_EVENT_PHASE_PRE, 0, on_tick_event, 0,
                            &subscription) != 0)
    return 1;
  host->log(host_userdata, TECTON_LOG_INFO, TECTON_STR("C plugin started"));
  return 0;
}

static void TECTON_PLUGIN_CALL on_shutdown(tecton_plugin_context *value,
                                            uint32_t reason) {
  (void)value;
  (void)reason;
  if (subscription != 0) {
    host->event_unsubscribe(host_userdata, subscription);
    subscription = 0;
  }
  host->log(host_userdata, TECTON_LOG_INFO, TECTON_STR("C plugin stopped"));
}

static void TECTON_PLUGIN_CALL on_unload(tecton_plugin_context *value) {
  (void)value;
  context = 0;
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
            .name = TECTON_STR("tecton-c-example"),
            .version = TECTON_STR("2.0.0"),
            .description = TECTON_STR("Minimal ABI 2.0 integration plugin"),
            .api = {TECTON_PLUGIN_ABI_MAJOR, TECTON_PLUGIN_ABI_MINOR, 0, 0},
            .required_features = TECTON_FEATURE_EVENTS | TECTON_FEATURE_LOGGING,
            .optional_features = 0,
        },
    .on_load = on_load,
    .on_start = on_start,
    .on_shutdown = on_shutdown,
    .on_unload = on_unload,
    .on_ready = 0,
};

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
  (void)context;
  return TECTON_RESULT_OK;
}
