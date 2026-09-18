#include <conduit_plugin.h>

static conduit_plugin_context *context;
static uint64_t subscription;
static const char name[] = "conduit-c-example";
static const char version[] = "1.0.0";
static const char description[] = "Minimal C ABI integration plugin";
static const char started_message[] = "C plugin started";
static const char stopped_message[] = "C plugin stopped";

static int32_t CONDUIT_PLUGIN_CALL on_load(conduit_plugin_context *value) {
  context = value;
  return context != 0 && context->host != 0 ? 0 : 1;
}

static void CONDUIT_PLUGIN_CALL on_event(void *userdata,
                                         const conduit_event_view *event) {
  (void)userdata;
  conduit_plugin_context *value = context;
  if (event->event_id != CONDUIT_EVENT_SERVER_TICK ||
      event->data_size != sizeof(conduit_server_tick_event))
    return;
  const conduit_server_tick_event *tick = event->data;
  if (tick->tick == 0 || value == 0 || value->host == 0 ||
      value->host->log == 0)
    return;
  static const char message_text[] = "C plugin observed server tick";
  conduit_string_view message = {message_text, sizeof(message_text) - 1};
  value->host->log(value->host->userdata, 1, message);
}

static int32_t CONDUIT_PLUGIN_CALL on_start(conduit_plugin_context *value) {
  if (value == 0 || value->host == 0 || value->host->log == 0)
    return 1;
  conduit_string_view message = {started_message, sizeof(started_message) - 1};
  value->host->log(value->host->userdata, 1, message);
  if (value->host->event_subscribe(
          value->host->userdata, CONDUIT_EVENT_SERVER_TICK,
          CONDUIT_EVENT_PHASE_PRE, 0, on_event, value, &subscription) != 0)
    return 1;
  return 0;
}

static void CONDUIT_PLUGIN_CALL on_shutdown(conduit_plugin_context *value,
                                            uint32_t reason) {
  (void)reason;
  if (value != 0 && value->host != 0 && value->host->event_unsubscribe != 0 &&
      subscription != 0) {
    value->host->event_unsubscribe(value->host->userdata, subscription);
    subscription = 0;
  }
  if (value != 0 && value->host != 0 && value->host->log != 0) {
    conduit_string_view message = {stopped_message,
                                   sizeof(stopped_message) - 1};
    value->host->log(value->host->userdata, 1, message);
  }
}

static void CONDUIT_PLUGIN_CALL on_unload(conduit_plugin_context *value) {
  (void)value;
  context = 0;
}

static const conduit_plugin_descriptor descriptor = {
    sizeof(conduit_plugin_descriptor),
    CONDUIT_PLUGIN_DESCRIPTOR_VERSION,
    {sizeof(conduit_plugin_metadata),
     {name, sizeof(name) - 1},
     {version, sizeof(version) - 1},
     {description, sizeof(description) - 1},
     {CONDUIT_PLUGIN_ABI_MAJOR, CONDUIT_PLUGIN_ABI_MINOR, 2169},
     0},
    on_load,
    on_start,
    on_shutdown,
    on_unload};

CONDUIT_PLUGIN_EXPORT const conduit_plugin_descriptor *CONDUIT_PLUGIN_CALL
conduit_plugin_get_descriptor(uint32_t host_abi_major,
                              uint32_t host_abi_minor) {
  if (host_abi_major != CONDUIT_PLUGIN_ABI_MAJOR ||
      host_abi_minor > CONDUIT_PLUGIN_ABI_MINOR)
    return 0;
  return &descriptor;
}
