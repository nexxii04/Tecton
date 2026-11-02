#include <tecton_plugin.h>

TECTON_PLUGIN_EXPORT const void *TECTON_PLUGIN_CALL
tecton_plugin_get_descriptor(uint32_t host_abi_major, uint32_t host_abi_minor) {
  (void)host_abi_major;
  (void)host_abi_minor;
  return 0;
}
