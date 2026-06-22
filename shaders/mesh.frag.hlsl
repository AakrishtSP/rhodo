struct PSInput {
    float4 position : SV_Position;
    float3 normal   : NORMAL;
};

// Cheap directional lambert against a fixed light, plus ambient, so the mesh
// reads as 3D without a real lighting system. ponytail: swap for material/light
// uniforms when there's more than one object.
float4 main(PSInput input) : SV_Target {
    float3 n = normalize(input.normal);
    float3 light = normalize(float3(0.5, 0.8, 0.6));
    float diffuse = max(dot(n, light), 0.0);
    float shade = 0.2 + 0.8 * diffuse;
    return float4(shade.xxx, 1.0);
}
