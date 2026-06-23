// Unlit flat-color fragment shader. Useful for debug geometry, sprites.
// ponytail: solid white output, per-vertex color when you need it.
float4 main(float4 position : SV_Position) : SV_Target {
    return float4(1.0, 1.0, 1.0, 1.0);
}
