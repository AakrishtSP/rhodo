// Minimal C wrapper over JoltPhysics v5.6. Follows Samples/HelloWorld: 2 object
// layers (static/dynamic), 1:1 broadphase mapping, BoxShape bodies.
#include "jolt_shim.h"

#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Character/CharacterVirtual.h>
#include <Jolt/Physics/Collision/CollideShape.h>
#include <Jolt/Physics/Collision/NarrowPhaseQuery.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/CapsuleShape.h>
#include <Jolt/Physics/Collision/Shape/CylinderShape.h>
#include <Jolt/Physics/Collision/Shape/PlaneShape.h>
#include <Jolt/Physics/Collision/Shape/RotatedTranslatedShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>

#include <thread>
#include <unordered_map>

JPH_SUPPRESS_WARNINGS
using namespace JPH;

namespace Layers {
static constexpr ObjectLayer NON_MOVING = 0;
static constexpr ObjectLayer MOVING = 1;
static constexpr ObjectLayer NUM_LAYERS = 2;
}

class ObjectLayerPairFilterImpl : public ObjectLayerPairFilter {
public:
    virtual bool ShouldCollide(ObjectLayer a, ObjectLayer b) const override {
        if (a == Layers::NON_MOVING)
            return b == Layers::MOVING;
        if (a == Layers::MOVING)
            return true;
        return false;
    }
};

namespace BroadPhaseLayers {
static constexpr BroadPhaseLayer NON_MOVING(0);
static constexpr BroadPhaseLayer MOVING(1);
static constexpr uint NUM_LAYERS(2);
}

class BPLayerInterfaceImpl final : public BroadPhaseLayerInterface {
public:
    BPLayerInterfaceImpl() {
        mMap[Layers::NON_MOVING] = BroadPhaseLayers::NON_MOVING;
        mMap[Layers::MOVING] = BroadPhaseLayers::MOVING;
    }
    virtual uint GetNumBroadPhaseLayers() const override { return BroadPhaseLayers::NUM_LAYERS; }
    virtual BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer l) const override { return mMap[l]; }

private:
    BroadPhaseLayer mMap[Layers::NUM_LAYERS];
};

class ObjectVsBroadPhaseLayerFilterImpl : public ObjectVsBroadPhaseLayerFilter {
public:
    virtual bool ShouldCollide(ObjectLayer l1, BroadPhaseLayer l2) const override {
        if (l1 == Layers::NON_MOVING)
            return l2 == BroadPhaseLayers::MOVING;
        if (l1 == Layers::MOVING)
            return true;
        return false;
    }
};

namespace {
TempAllocatorImpl *temp_alloc = nullptr;
JobSystemThreadPool *job_system = nullptr;
PhysicsSystem *physics = nullptr;
BPLayerInterfaceImpl *bp_interface = nullptr;
ObjectVsBroadPhaseLayerFilterImpl *obj_vs_bp = nullptr;
ObjectLayerPairFilterImpl *obj_vs_obj = nullptr;
std::unordered_map<uint32_t, CharacterVirtual *> characters;
uint32_t next_character_id = 0;

// Shared body creation: shape + pose + motion type + layer.
uint32_t add_body(const Shape *shape, const float pos[3], int body_type) {
    EMotionType motion = body_type == JOLT_BODY_STATIC ? EMotionType::Static
                       : body_type == JOLT_BODY_KINEMATIC ? EMotionType::Kinematic
                       : EMotionType::Dynamic;
    // Kinematic bodies share the non-moving layer: they collide with dynamic
    // bodies (that is what makes a platform push) and never with static ones.
    ObjectLayer layer = motion == EMotionType::Dynamic ? Layers::MOVING : Layers::NON_MOVING;
    BodyCreationSettings bc(shape, RVec3(pos[0], pos[1], pos[2]), Quat::sIdentity(), motion, layer);
    BodyID id = physics->GetBodyInterface().CreateAndAddBody(bc, EActivation::Activate);
    if (id.IsInvalid())
        return BodyID::cInvalidBodyID;
    return id.GetIndexAndSequenceNumber();
}
} // namespace

bool Jolt_Init(void) {
    RegisterDefaultAllocator();
    Factory::sInstance = new Factory();
    RegisterTypes();

    temp_alloc = new TempAllocatorImpl(10 * 1024 * 1024);
    job_system = new JobSystemThreadPool(cMaxPhysicsJobs, cMaxPhysicsBarriers, (int)std::thread::hardware_concurrency() - 1);

    bp_interface = new BPLayerInterfaceImpl();
    obj_vs_bp = new ObjectVsBroadPhaseLayerFilterImpl();
    obj_vs_obj = new ObjectLayerPairFilterImpl();

    physics = new PhysicsSystem();
    // ponytail: 1024 bodies/pairs/contacts matches transforms[]. Raise together.
    physics->Init(1024, 0, 1024, 1024, *bp_interface, *obj_vs_bp, *obj_vs_obj);
    return true;
}

void Jolt_Shutdown(void) {
    for (auto &pair : characters)
        delete pair.second;
    characters.clear();
    next_character_id = 0;
    delete physics;
    delete obj_vs_obj;
    delete obj_vs_bp;
    delete bp_interface;
    delete job_system;
    delete temp_alloc;
    UnregisterTypes();
    delete Factory::sInstance;
    Factory::sInstance = nullptr;
}

uint32_t Jolt_AddBox(const float pos[3], const float half_extent[3], int body_type) {
    return add_body(new BoxShape(Vec3(half_extent[0], half_extent[1], half_extent[2])), pos, body_type);
}

uint32_t Jolt_AddSphere(const float pos[3], float radius, int body_type) {
    return add_body(new SphereShape(radius), pos, body_type);
}

uint32_t Jolt_AddCapsule(const float pos[3], float radius, float half_height, int body_type) {
    return add_body(new CapsuleShape(half_height, radius), pos, body_type);
}

uint32_t Jolt_AddCylinder(const float pos[3], float radius, float half_height, int body_type) {
    return add_body(new CylinderShape(half_height, radius), pos, body_type);
}

uint32_t Jolt_AddPlane(const float pos[3], const float normal[3], int body_type) {
    Vec3 n(normal[0], normal[1], normal[2]);
    if (n.LengthSq() < 1.0e-12f)
        return BodyID::cInvalidBodyID;
    return add_body(new PlaneShape(Plane(n.Normalized(), 0.0f)), pos, body_type);
}

void Jolt_SetSensor(uint32_t id, bool is_sensor) {
    physics->GetBodyInterface().SetIsSensor(BodyID(id), is_sensor);
}

// All bodies whose shape intersects this body's shape (self excluded). Uses
// the body's current pose, so call after Step (or for a static sensor, any
// time). Deduplicates and caps at max_count.
int Jolt_Overlaps(uint32_t id, uint32_t *out_ids, int max_count) {
    BodyInterface &bi = physics->GetBodyInterface();
    BodyID self(id);
    RefConst<Shape> shape = bi.GetShape(self);
    if (shape == nullptr || max_count <= 0)
        return 0;

    class Collector final : public CollideShapeCollector {
    public:
        Collector(BodyID in_self, uint32_t *in_out, int in_max)
            : m_self(in_self), m_out(in_out), m_max(in_max) {}

        void AddHit(const CollideShapeResult &in_result) override {
            BodyID body = in_result.mBodyID2;
            if (body == m_self || m_count >= m_max)
                return;
            uint32_t hit = body.GetIndexAndSequenceNumber();
            for (int i = 0; i < m_count; ++i)
                if (m_out[i] == hit)
                    return;
            m_out[m_count++] = hit;
        }

        BodyID m_self;
        uint32_t *m_out;
        int m_max;
        int m_count = 0;
    };

    Collector collector(self, out_ids, max_count);
    CollideShapeSettings settings;
    RMat44 xf = bi.GetCenterOfMassTransform(self);
    physics->GetNarrowPhaseQuery().CollideShape(
        shape, Vec3::sReplicate(1.0f), xf, settings, xf.GetTranslation(), collector);
    return collector.m_count;
}

void Jolt_SetBodyVelocity(uint32_t id, const float vel[3]) {
    BodyInterface &bi = physics->GetBodyInterface();
    bi.SetLinearVelocity(BodyID(id), Vec3(vel[0], vel[1], vel[2]));
    bi.ActivateBody(BodyID(id));
}

void Jolt_Step(float dt) {
    physics->Update(dt, 1, temp_alloc, job_system);
}

void Jolt_RemoveBody(uint32_t id) {
    BodyInterface &bi = physics->GetBodyInterface();
    bi.RemoveBody(BodyID(id));
    bi.DestroyBody(BodyID(id));
}

void Jolt_GetTransform(uint32_t id, float out_pos[3], float out_quat[4]) {
    BodyInterface &bi = physics->GetBodyInterface();
    RVec3 p = bi.GetPosition(BodyID(id));
    Quat q = bi.GetRotation(BodyID(id));
    out_pos[0] = p.GetX();
    out_pos[1] = p.GetY();
    out_pos[2] = p.GetZ();
    out_quat[0] = q.GetX();
    out_quat[1] = q.GetY();
    out_quat[2] = q.GetZ();
    out_quat[3] = q.GetW();
}

uint32_t Jolt_AddCharacter(const float feet_pos[3], float radius, float half_height) {
    // Bottom of the capsule at the origin: Jolt's character contract (walk
    // stairs / stick to floor measure from the feet).
    RotatedTranslatedShapeSettings shape_settings(
        Vec3(0, half_height + radius, 0), Quat::sIdentity(),
        new CapsuleShape(half_height, radius));
    ShapeSettings::ShapeResult shape = shape_settings.Create();
    if (shape.HasError())
        return BodyID::cInvalidBodyID;

    CharacterVirtualSettings settings;
    settings.mShape = shape.Get();
    settings.mSupportingVolume = Plane(Vec3::sAxisY(), -radius); // lower sphere supports
    CharacterVirtual *character = new CharacterVirtual(
        &settings, RVec3(feet_pos[0], feet_pos[1], feet_pos[2]),
        Quat::sIdentity(), 0, physics);

    uint32_t id = next_character_id++;
    characters[id] = character;
    return id;
}

void Jolt_CharacterMove(uint32_t id, const float velocity[3], float dt,
                        float out_feet_pos[3], bool *out_grounded) {
    out_feet_pos[0] = out_feet_pos[1] = out_feet_pos[2] = 0;
    *out_grounded = false;
    auto it = characters.find(id);
    if (it == characters.end())
        return;

    CharacterVirtual *character = it->second;
    character->SetLinearVelocity(Vec3(velocity[0], velocity[1], velocity[2]));
    // Gravity is the caller's business (baked into velocity), so pass zero:
    // the engine does not add its own and the game owns jump feel.
    character->ExtendedUpdate(dt, Vec3::sZero(), CharacterVirtual::ExtendedUpdateSettings{},
        {}, {}, {}, {}, *temp_alloc);

    RVec3 p = character->GetPosition();
    out_feet_pos[0] = (float)p.GetX();
    out_feet_pos[1] = (float)p.GetY();
    out_feet_pos[2] = (float)p.GetZ();
    *out_grounded = character->IsSupported();
}

void Jolt_RemoveCharacter(uint32_t id) {
    auto it = characters.find(id);
    if (it == characters.end())
        return;
    delete it->second;
    characters.erase(it);
}
