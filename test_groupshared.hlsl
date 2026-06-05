groupshared float invalidData[64];

[shader("pixel")]
float4 PSMain() : SV_Target {
    return float4(1,0,0,1);
}