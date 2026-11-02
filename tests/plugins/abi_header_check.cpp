#include <tecton_plugin.h>

static_assert(sizeof(tecton_host_api) == 120, "host api size");
static_assert(sizeof(tecton_plugin_descriptor) == 136, "descriptor size");
static_assert(sizeof(tecton_plugin_metadata) == 80, "metadata size");
static_assert(sizeof(tecton_host_query) == 40, "host query size");
static_assert(sizeof(tecton_plugin_info) == 56, "plugin info size");
static_assert(TECTON_PLUGIN_ABI_MAJOR == 2, "abi major");
static_assert(TECTON_PLUGIN_ABI_MINOR == 0, "abi minor");
static_assert(TECTON_PLUGIN_DESCRIPTOR_VERSION == 2, "descriptor version");

extern "C" int tecton_plugin_header_check(void) {
  return static_cast<int>(TECTON_ABI_FINGERPRINT != 0);
}
