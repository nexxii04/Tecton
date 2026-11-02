#include <tecton_plugin.h>

TECTON_PLUGIN_EXPORT int32_t TECTON_PLUGIN_CALL
tecton_plugin_query(const tecton_host_query *query, tecton_plugin_info *info) {
  if (query == 0 || info == 0 || info->struct_size < sizeof(*info))
    return TECTON_RESULT_INVALID_ARGUMENT;
  info->status = TECTON_PLUGIN_STATUS_OK;
  info->abi_major = TECTON_PLUGIN_ABI_MAJOR;
  info->abi_minor = TECTON_PLUGIN_ABI_MINOR;
  info->abi_fingerprint = TECTON_ABI_FINGERPRINT ^ UINT64_C(1);
  info->descriptor = (const tecton_plugin_descriptor *)(uintptr_t)1;
  info->diagnostic = TECTON_STR("deliberate fingerprint mismatch");
  info->reserved = 0;
  (void)query;
  return TECTON_RESULT_OK;
}
