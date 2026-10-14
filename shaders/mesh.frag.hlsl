struct PSInput {
    float4 position : SV_Position;
    float3 normal   : NORMAL;
};

// Cheap directional lambert against a fixed light, plus ambient, so the mesh
// reads as 3D without a real lighting system. ponytail: swap for material/light
// uniforms when there's more than one object.
[[vk::push_constant]]
struct {
    float4x4 mvp;
    float4 color;
    float4 light; // xyz = direction (to sun), w = ambient 0..1
} pc;

float4 main(PSInput input) : SV_Target {
    float3 n = normalize(input.normal);
    float3 light = normalize(pc.light.xyz);
    float diffuse = max(dot(n, light), 0.0);
    float shade = pc.light.w + (1.0 - pc.light.w) * diffuse;
    return float4(shade.xxx, 1.0) * pc.color;
}
