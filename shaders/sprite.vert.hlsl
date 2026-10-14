struct VSInput {
    float3 position : POSITION;
    float2 uv       : TEXCOORD0;
};

struct VSOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
};

// Same 64-byte ortho*model push constant the mesh pipeline uses.
[[vk::push_constant]]
struct {
    float4x4 mvp;
} pc;

VSOutput main(VSInput input) {
    VSOutput output;
    output.position = mul(pc.mvp, float4(input.position, 1.0));
    output.uv       = input.uv;
    return output;
}
