[shader("vertex")]
float4 VSMain(float3 pos : POSITION) : SV_Position {
    return float4(pos, 1.0);
}

[shader("pixel")]
float4 PSMain(float2 uv : TEXCOORD) : SV_Target {
    return float4(1.0, 0.0, 0.0, 1.0);
}