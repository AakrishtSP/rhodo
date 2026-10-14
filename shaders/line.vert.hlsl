struct VSInput {
    float3 position : POSITION;
    float3 color    : COLOR;
};

struct VSOutput {
    float4 position : SV_Position;
    float3 color    : COLOR;
};

// Same 64-byte viewProj push constant the mesh pipeline uses (model is
// identity for debug lines, so the CPU pushes proj*view).
[[vk::push_constant]]
struct {
    float4x4 mvp;
} pc;

VSOutput main(VSInput input) {
    VSOutput output;
    output.position = mul(pc.mvp, float4(input.position, 1.0));
    output.color    = input.color;
    return output;
}
