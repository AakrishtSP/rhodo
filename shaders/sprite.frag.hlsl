// Texture + sampler share binding 0 so SPIR-V sees one combined image sampler,
// matching the engine's single COMBINED_IMAGE_SAMPLER descriptor.
[[vk::binding(0, 0)]] Texture2D<float4> sprite_tex;
[[vk::binding(0, 0)]] SamplerState sprite_samp;

struct PSInput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
};

float4 main(PSInput input) : SV_Target {
    return sprite_tex.Sample(sprite_samp, input.uv);
}
