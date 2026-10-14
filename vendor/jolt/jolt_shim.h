// Minimal C API over Jolt: init/shutdown, static + dynamic box bodies, fixed
// step, body transforms. ponytail: boxes only, 1024 bodies, single-threaded
// job system. More shapes, removal, and a thread pool when a game needs them.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool Jolt_Init(void);
void Jolt_Shutdown(void);

// Add an axis-aligned box. Returns the Jolt body id, or 0xFFFFFFFF on failure.
uint32_t Jolt_AddBox(const float pos[3], const float half_extent[3], bool is_static);
void Jolt_Step(float dt);
// Body transform: world position + unit quaternion (x, y, z, w).
void Jolt_GetTransform(uint32_t id, float out_pos[3], float out_quat[4]);

#ifdef __cplusplus
} // extern "C"
#endif
