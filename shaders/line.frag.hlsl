struct PSInput {
    float4 position : SV_Position;
    float3 color    : COLOR;
};

// Unlit vertex color. No depth test in the pipeline, so lines draw on top.
float4 main(PSInput input) : SV_Target {
    return float4(input.color, 1.0);
}
