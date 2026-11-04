#include <tecton_plugin.h>

#ifndef TECTON_REASON_CASE
#define TECTON_REASON_CASE 0
#endif

#define TECTON_REASON_ABI_MAJOR 1
#define TECTON_REASON_ABI_MINOR 2
#define TECTON_REASON_DESCRIPTOR 3
#define TECTON_REASON_METADATA 4
#define TECTON_REASON_REQUIRED_FEATURE 5
#define TECTON_REASON_MISSING_CALLBACK 6

static int32_t TECTON_PLUGIN_CALL on_load(tecton_plugin_context *value) {
  (void)value;
  return 0;
}

static int32_t TECTON_PLUGIN_CALL on_start(tecton_plugin_context *value) {
  (void)value;
  return 0;
}

static void TECTON_PLUGIN_CALL on_shutdown(tecton_plugin_context *value,
                                           uint32_t reason) {
  (void)value;
  (void)reason;
}

static void TECTON_PLUGIN_CALL on_unload(tecton_plugin_context *value) {
  (void)value;
}

#define TECTON_REASON_METADATA_VALUE                                          \
  {                                                                          \
    .struct_size = sizeof(tecton_plugin_metadata),                            \
    .plugin_flags = 0,                                                       \
    .name = TECTON_STR("tecton-c-reason"),                                    \
    .version = TECTON_STR("2.0.0"),                                          \
    .description = TECTON_STR("Load reason fixture"),                         \
    .api = {TECTON_PLUGIN_ABI_MAJOR, TECTON_PLUGIN_ABI_MINOR, 0, 0},        \
    .required_features = 0,                                                   \
    .optional_features = 0,                                                   \
  }

static const tecton_plugin_descriptor descriptor = {
    .struct_size = sizeof(tecton_plugin_descriptor),
    .descriptor_version = TECTON_PLUGIN_DESCRIPTOR_VERSION,
    .abi_fingerprint = TECTON_ABI_FINGERPRINT,
    .metadata = TECTON_REASON_METADATA_VALUE,
    .on_load = on_load,
    .on_start = on_start,
    .on_shutdown = on_shutdown,
    .on_unload = on_unload,
    .on_ready = 0,
};

static const tecton_plugin_descriptor descriptor_bad_version = {
    .struct_size = sizeof(tecton_plugin_descriptor),
    .descriptor_version = 1,
    .abi_fingerprint = TECTON_ABI_FINGERPRINT,
    .metadata = TECTON_REASON_METADATA_VALUE,
    .on_load = on_load,
    .on_start = on_start,
    .on_shutdown = on_shutdown,
    .on_unload = on_unload,
    .on_ready = 0,
};

static const tecton_plugin_descriptor descriptor_bad_metadata = {
    .struct_size = sizeof(tecton_plugin_descriptor),
    .descriptor_version = TECTON_PLUGIN_DESCRIPTOR_VERSION,
    .abi_fingerprint = TECTON_ABI_FINGERPRINT,
    .metadata =
        {
            .struct_size = sizeof(tecton_plugin_metadata),
            .plugin_flags = 0,
            .name = {0, 0},
            .version = TECTON_STR("2.0.0"),
            .description = TECTON_STR("Load reason fixture"),
            .api = {TECTON_PLUGIN_ABI_MAJOR, TECTON_PLUGIN_ABI_MINOR, 0, 0},
            .required_features = 0,
            .optional_features = 0,
        },
    .on_load = on_load,
    .on_start = on_start,
    .on_shutdown = on_shutdown,
    .on_unload = on_unload,
    .on_ready = 0,
};

static const tecton_plugin_descriptor descriptor_required_feature = {
    .struct_size = sizeof(tecton_plugin_descriptor),
    .descriptor_version = TECTON_PLUGIN_DESCRIPTOR_VERSION,
    .abi_fingerprint = TECTON_ABI_FINGERPRINT,
    .metadata =
        {
            .struct_size = sizeof(tecton_plugin_metadata),
            .plugin_flags = 0,
            .name = TECTON_STR("tecton-c-reason"),
            .version = TECTON_STR("2.0.0"),
            .description = TECTON_STR("Load reason fixture"),
            .api = {TECTON_PLUGIN_ABI_MAJOR, TECTON_PLUGIN_ABI_MINOR, 0, 0},
            .required_features = UINT64_C(1) << 63,
            .optional_features = 0,
        },
    .on_load = on_load,
    .on_start = on_start,
    .on_shutdown = on_shutdown,
    .on_unload = on_unload,
    .on_ready = 0,
};

static const tecton_plugin_descriptor descriptor_missing_callback = {
    .struct_size = sizeof(tecton_plugin_descriptor),
    .descriptor_version = TECTON_PLUGIN_DESCRIPTOR_VERSION,
    .abi_fingerprint = TECTON_ABI_FINGERPRINT,
    .metadata = TECTON_REASON_METADATA_VALUE,
    .on_load = 0,
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
  info->abi_major = TECTON_PLUGIN_ABI_MAJOR;
  info->abi_minor = TECTON_PLUGIN_ABI_MINOR;
  info->abi_fingerprint = TECTON_ABI_FINGERPRINT;
  info->reserved = 0;

#if TECTON_REASON_CASE == TECTON_REASON_ABI_MAJOR
  info->status = TECTON_PLUGIN_STATUS_ABI_MAJOR;
  return TECTON_RESULT_VERSION;
#elif TECTON_REASON_CASE == TECTON_REASON_ABI_MINOR
  info->status = TECTON_PLUGIN_STATUS_ABI_MINOR;
  return TECTON_RESULT_VERSION;
#endif

  info->status = TECTON_PLUGIN_STATUS_OK;

#if TECTON_REASON_CASE == TECTON_REASON_DESCRIPTOR
  info->descriptor = &descriptor_bad_version;
#elif TECTON_REASON_CASE == TECTON_REASON_METADATA
  info->descriptor = &descriptor_bad_metadata;
#elif TECTON_REASON_CASE == TECTON_REASON_REQUIRED_FEATURE
  info->descriptor = &descriptor_required_feature;
#elif TECTON_REASON_CASE == TECTON_REASON_MISSING_CALLBACK
  info->descriptor = &descriptor_missing_callback;
#else
  info->descriptor = &descriptor;
#endif
  return TECTON_RESULT_OK;
}
