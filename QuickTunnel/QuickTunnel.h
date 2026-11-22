#pragma once
#include <stdint.h>

// Start returns immediately. Status returns an owned UTF-8 string for the caller to free.
uint64_t SSQuickTunnelStart(uint16_t port, const char *sessionKey);
char *SSQuickTunnelStatus(uint64_t handle);
void SSQuickTunnelStop(uint64_t handle);
