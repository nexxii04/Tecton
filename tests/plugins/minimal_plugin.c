#include <tecton_plugin.h>

static tecton_plugin_context *context;
static uint64_t subscription;
static const char name[] = "tecton-c-example";
static const char version[] = "1.0.0";
static const char description[] = "Minimal C ABI integration plugin";
static const char started_message[] = "C plugin started";
static const char stopped_message[] = "C plugin stopped";

static int32_t TECTON_PLUGIN_CALL on_load(tecton_plugin_context *value) {
  context = value;
  return context != 0 && context->host != 0 ? 0 : 1;
}

static void TECTON_PLUGIN_CALL on_event(void *userdata,
                                         const tecton_event_view *event) {
  (void)userdata;
  tecton_plugin_context *value = context;
  if (event->event_id != TECTON_EVENT_SERVER_TICK ||
      event->data_size != sizeof(tecton_server_tick_event))
    return;
  const tecton_server_tick_event *tick = event->data;
  if (tick->tick == 0 || value == 0 || value->host == 0 ||
      value->host->log == 0)
    return;
  static const char message_text[] = "C plugin observed server tick";
  tecton_string_view message = {message_text, sizeof(message_text) - 1};
  value->host->log(value->host->userdata, 1, message);
}

static int32_t TECTON_PLUGIN_CALL on_start(tecton_plugin_context *value) {
  if (value == 0 || value->host == 0 || value->host->log == 0)
    return 1;
  tecton_string_view message = {started_message, sizeof(started_message) - 1};
  value->host->log(value->host->userdata, 1, message);
  if (value->host->event_subscribe(
          value->host->userdata, TECTON_EVENT_SERVER_TICK,
          TECTON_EVENT_PHASE_PRE, 0, on_event, value, &subscription) != 0)
    return 1;
  return 0;
}

static void TECTON_PLUGIN_CALL on_shutdown(tecton_plugin_context *value,
                                            uint32_t reason) {
  (void)reason;
  if (value != 0 && value->host != 0 && value->host->event_unsubscribe != 0 &&
      subscription != 0) {
    value->host->event_unsubscribe(value->host->userdata, subscription);
    subscription = 0;
  }
  if (value != 0 && value->host != 0 && value->host->log != 0) {
    tecton_string_view message = {stopped_message,
                                   sizeof(stopped_message) - 1};
    value->host->log(value->host->userdata, 1, message);
  }
}

static void TECTON_PLUGIN_CALL on_unload(tecton_plugin_context *value) {
  (void)value;
  context = 0;
}

static const tecton_plugin_descriptor descriptor = {
    sizeof(tecton_plugin_descriptor),
    TECTON_PLUGIN_DESCRIPTOR_VERSION,
    {sizeof(tecton_plugin_metadata),
     {name, sizeof(name) - 1},
     {version, sizeof(version) - 1},
     {description, sizeof(description) - 1},
     {TECTON_PLUGIN_ABI_MAJOR, TECTON_PLUGIN_DESCRIPTOR_QUERY_MINOR, 2169},
     0},
    on_load,
    on_start,
    on_shutdown,
    on_unload};

TECTON_PLUGIN_EXPORT const tecton_plugin_descriptor *TECTON_PLUGIN_CALL
tecton_plugin_get_descriptor(uint32_t host_abi_major,
                              uint32_t host_abi_minor) {
  if (host_abi_major != TECTON_PLUGIN_ABI_MAJOR ||
      host_abi_minor > TECTON_PLUGIN_ABI_MINOR)
    return 0;
  return &descriptor;
}
