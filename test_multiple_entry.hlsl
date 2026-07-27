struct VSInput {
    float3 position : SV_Position;
    float2 uv : SV_Position;
};

struct VSOutput {
    float4 position : SV_Position;
    float2 uv : SV_Position;
};

float4 ApplyFog(float4 color, float depth) {
    float fogFactor = saturate(depth / 100.0);
    return lerp(color, float4(0.5, 0.5, 0.5, 1.0), fogFactor);
}

[shader("vertex")]
VSOutput VSMain(VSInput input) {
    VSOutput output;
    output.position = float4(input.position, 1.0);
    output.uv = input.uv;
    return output;
}

[shader("pixel")]
float4 PSMain(VSOutput input) : SV_Target {
    float4 color = float4(input.uv, 0.0, 1.0);
    return ApplyFog(color, input.position.z);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void CSMain(uint3 tid : SV_DispatchThreadID) {
    
}