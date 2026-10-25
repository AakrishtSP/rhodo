// Minimal C API over Jolt: init/shutdown, box bodies (static/kinematic/dynamic),
// a kinematic capsule character, fixed step, body transforms. ponytail: boxes +
// one capsule, 1024 bodies, single-threaded job system. More shapes, contacts,
// and character-vs-character when a game needs them.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Body motion type (values match JPH::EMotionType).
typedef enum {
    JOLT_BODY_STATIC = 0,
    JOLT_BODY_KINEMATIC = 1,
    JOLT_BODY_DYNAMIC = 2,
} JoltBodyType;

bool Jolt_Init(void);
void Jolt_Shutdown(void);

// Add an axis-aligned box. Returns the Jolt body id, or 0xFFFFFFFF on failure.
uint32_t Jolt_AddBox(const float pos[3], const float half_extent[3], int body_type);
// Other shapes. Capsules/cylinders are upright (Y), capsule/cylinder
// `half_height` is the half height of the straight part (radius excluded).
uint32_t Jolt_AddSphere(const float pos[3], float radius, int body_type);
uint32_t Jolt_AddCapsule(const float pos[3], float radius, float half_height, int body_type);
uint32_t Jolt_AddCylinder(const float pos[3], float radius, float half_height, int body_type);
// Infinite plane through `pos` with the given normal; static bodies only.
uint32_t Jolt_AddPlane(const float pos[3], const float normal[3], int body_type);
void Jolt_RemoveBody(uint32_t id);
// Sensor = pass-through collider: no contact response, still found by queries.
void Jolt_SetSensor(uint32_t id, bool is_sensor);
// Bodies whose shape intersects body `id` (self excluded). Writes up to
// max_count Jolt ids, returns the count. Backs `Physics.overlaps` for triggers.
int Jolt_Overlaps(uint32_t id, uint32_t *out_ids, int max_count);
// For kinematic and dynamic bodies (kinematic platforms need this; static ignores).
void Jolt_SetBodyVelocity(uint32_t id, const float vel[3]);
void Jolt_Step(float dt);
// Body transform: world position + unit quaternion (x, y, z, w).
void Jolt_GetTransform(uint32_t id, float out_pos[3], float out_quat[4]);

// Kinematic capsule character (collide-and-slide, stairs, slopes, ground check).
// Positions are the capsule's *feet* (shape bottom at the origin). Gravity is
// not simulated: fold it into `velocity` before calling. Returns 0xFFFFFFFF on
// failure. Max slope 50deg, step up 0.4, stick-to-floor 0.5 (Jolt defaults).
uint32_t Jolt_AddCharacter(const float feet_pos[3], float radius, float half_height);
void Jolt_CharacterMove(uint32_t id, const float velocity[3], float dt,
                        float out_feet_pos[3], bool *out_grounded);
void Jolt_RemoveCharacter(uint32_t id);

#ifdef __cplusplus
} // extern "C"
#endif
