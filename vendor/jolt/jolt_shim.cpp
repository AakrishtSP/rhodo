// Minimal C wrapper over JoltPhysics v5.6. Follows Samples/HelloWorld: 2 object
// layers (static/dynamic), 1:1 broadphase mapping, BoxShape bodies.
#include "jolt_shim.h"

#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>

#include <thread>

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

uint32_t Jolt_AddBox(const float pos[3], const float half_extent[3], bool is_static) {
    BoxShapeSettings settings(Vec3(half_extent[0], half_extent[1], half_extent[2]));
    settings.SetEmbedded();
    ShapeSettings::ShapeResult result = settings.Create();
    if (result.HasError())
        return BodyID::cInvalidBodyID;
    BodyCreationSettings bc(result.Get(), RVec3(pos[0], pos[1], pos[2]), Quat::sIdentity(),
        is_static ? EMotionType::Static : EMotionType::Dynamic,
        is_static ? Layers::NON_MOVING : Layers::MOVING);
    BodyID id = physics->GetBodyInterface().CreateAndAddBody(bc, EActivation::Activate);
    if (id.IsInvalid())
        return BodyID::cInvalidBodyID;
    return id.GetIndexAndSequenceNumber();
}

void Jolt_Step(float dt) {
    physics->Update(dt, 1, temp_alloc, job_system);
}

void Jolt_RemoveBox(uint32_t id) {
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
