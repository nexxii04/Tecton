#include <stdlib.h>
#include <tecton_plugin.h>

#define TECTON_BENCH_MAX_SUBSCRIBERS 128u

static const tecton_host_api *host;
static void *host_userdata;
static uint64_t subscriptions[TECTON_BENCH_MAX_SUBSCRIBERS];
static uint32_t subscriptions_len;
static uint16_t subscription_phase;

static void TECTON_PLUGIN_CALL on_tick(void *userdata,
                                       const tecton_event_view *event) {
  (void)userdata;
  (void)event;
}

static int32_t TECTON_PLUGIN_CALL on_load(tecton_plugin_context *context) {
  if (context == 0 || context->host == 0)
    return 1;
  host = context->host;
  host_userdata = host->userdata;

  const char *count = getenv("TECTON_BENCH_SUBSCRIBERS");
  long subscribers = count != 0 ? strtol(count, 0, 10) : 0;
  if (subscribers < 0)
    subscribers = 0;
  if (subscribers > (long)TECTON_BENCH_MAX_SUBSCRIBERS)
    subscribers = (long)TECTON_BENCH_MAX_SUBSCRIBERS;
  subscriptions_len = (uint32_t)subscribers;

  subscription_phase = TECTON_EVENT_PHASE_PRE;
  const char *phase = getenv("TECTON_BENCH_PHASE");
  if (phase != 0) {
    if (phase[0] == 'c')
      subscription_phase = TECTON_EVENT_PHASE_COMMIT;
    else if (phase[0] == 'p')
      subscription_phase = TECTON_EVENT_PHASE_POST;
  }
  return 0;
}

static int32_t TECTON_PLUGIN_CALL on_start(tecton_plugin_context *context) {
  (void)context;
  for (uint32_t index = 0; index < subscriptions_len; ++index) {
    const int32_t result = host->event_subscribe(
        host_userdata, TECTON_EVENT_SERVER_TICK, subscription_phase, 0, on_tick,
        0, &subscriptions[index]);
    if (result != TECTON_RESULT_OK)
      return 1;
  }
  return 0;
}

static void TECTON_PLUGIN_CALL on_shutdown(tecton_plugin_context *context,
                                           uint32_t reason) {
  (void)context;
  (void)reason;
  for (uint32_t index = 0; index < subscriptions_len; ++index) {
    if (subscriptions[index] == 0)
      continue;
    host->event_unsubscribe(host_userdata, subscriptions[index]);
    subscriptions[index] = 0;
  }
}

static void TECTON_PLUGIN_CALL on_unload(tecton_plugin_context *context) {
  (void)context;
  host = 0;
  host_userdata = 0;
  subscriptions_len = 0;
}

static void TECTON_PLUGIN_CALL on_ready(tecton_plugin_context *context) {
  (void)context;
}

static const tecton_plugin_descriptor descriptor = {
    .struct_size = sizeof(tecton_plugin_descriptor),
    .descriptor_version = TECTON_PLUGIN_DESCRIPTOR_VERSION,
    .abi_fingerprint = TECTON_ABI_FINGERPRINT,
    .metadata =
        {
            .struct_size = sizeof(tecton_plugin_metadata),
            .plugin_flags = 0,
            .name = TECTON_STR("tecton-bench"),
            .version = TECTON_STR("2.0.0"),
            .description = TECTON_STR("Hot-path benchmark subscriber plugin"),
            .api = {TECTON_PLUGIN_ABI_MAJOR, TECTON_PLUGIN_ABI_MINOR, 0, 0},
            .required_features = TECTON_FEATURE_EVENTS,
            .optional_features = 0,
        },
    .on_load = on_load,
    .on_start = on_start,
    .on_shutdown = on_shutdown,
    .on_unload = on_unload,
    .on_ready = on_ready,
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
  return TECTON_RESULT_OK;
}
