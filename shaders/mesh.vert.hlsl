struct VSInput {
    float3 position : POSITION;
    float3 normal   : NORMAL;
};

struct VSOutput {
    float4 position : SV_Position;
    float3 normal   : NORMAL;
};

// MVP pushed per frame (64 bytes). Transposed on the CPU side so mul(mvp, v)
// matches dxc's column-major packing.
[[vk::push_constant]]
struct {
    float4x4 mvp;
} pc;

VSOutput main(VSInput input) {
    VSOutput output;
    output.position = mul(pc.mvp, float4(input.position, 1.0));
    output.normal   = input.normal;
    return output;
}
