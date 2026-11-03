#include <stdio.h>
#include <stdlib.h>
#include <tecton_plugin.h>

#ifndef TECTON_TRACE_NAME
#define TECTON_TRACE_NAME "tecton-trace"
#endif
#ifndef TECTON_TRACE_LABEL
#define TECTON_TRACE_LABEL "trace"
#endif

static const tecton_host_api *host;
static void *host_userdata;
static uint32_t lifecycle_mask;

static FILE *trace_file(void) {
  const char *path = getenv("TECTON_PLUGIN_TRACE");
  if (path == 0)
    return 0;
  return fopen(path, "a");
}

static void trace(const char *phase) {
  FILE *file = trace_file();
  if (file == 0)
    return;
  fprintf(file, "%s:%s\n", TECTON_TRACE_LABEL, phase);
  fclose(file);
}

static void trace_players(const char *phase, size_t players) {
  FILE *file = trace_file();
  if (file == 0)
    return;
  fprintf(file, "%s:%s:%zu\n", TECTON_TRACE_LABEL, phase, players);
  fclose(file);
}

static int32_t TECTON_PLUGIN_CALL on_load(tecton_plugin_context *value) {
  if (value == 0 || value->host == 0)
    return 1;
  host = value->host;
  host_userdata = host->userdata;
  lifecycle_mask |= 1u;
  trace("load");
  return 0;
}

static int32_t TECTON_PLUGIN_CALL on_start(tecton_plugin_context *value) {
  (void)value;
  lifecycle_mask |= 2u;
  trace("start");
  return 0;
}

static void TECTON_PLUGIN_CALL on_ready(tecton_plugin_context *value) {
  (void)value;
  lifecycle_mask |= 4u;
  trace("ready");
}

static void TECTON_PLUGIN_CALL on_shutdown(tecton_plugin_context *value,
                                            uint32_t reason) {
  (void)value;
  (void)reason;
  size_t players = 0;
  const tecton_players_api *players_api = 0;
  if (host->get_interface(host_userdata, TECTON_INTERFACE_PLAYERS, 1, 0,
                          (const tecton_interface_header **)&players_api) ==
          TECTON_RESULT_OK &&
      players_api != 0 &&
      players_api->count(host_userdata, &players) == TECTON_RESULT_OK) {
    trace_players("shutdown", players);
  } else {
    trace("shutdown");
  }
  lifecycle_mask |= 8u;
}

static void TECTON_PLUGIN_CALL on_unload(tecton_plugin_context *value) {
  (void)value;
  lifecycle_mask |= 16u;
  trace("unload");
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
            .name = TECTON_STR(TECTON_TRACE_NAME),
            .version = TECTON_STR("2.0.0"),
            .description = TECTON_STR("Lifecycle order probe"),
            .api = {TECTON_PLUGIN_ABI_MAJOR, TECTON_PLUGIN_ABI_MINOR, 0, 0},
            .required_features = TECTON_FEATURE_CORE | TECTON_FEATURE_PLAYERS,
            .optional_features = 0,
        },
    .on_load = on_load,
    .on_start = on_start,
    .on_shutdown = on_shutdown,
    .on_unload = on_unload,
    .on_ready = on_ready,
};

TECTON_PLUGIN_EXPORT uint32_t TECTON_PLUGIN_CALL
tecton_trace_mask(void) {
  return lifecycle_mask;
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
  return TECTON_RESULT_OK;
}
