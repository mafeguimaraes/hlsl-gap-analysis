struct VSInput {
    float3 pos : POSITION;
    float2 uv  : TEXCOORD1;
    float4 col : COLOR;
};

struct VSOutput {
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD;
    float4 col : COLOR;
};

VSOutput VSMain(VSInput input) {
    VSOutput output;
    output.pos = float4(input.pos, 1.0);
    output.uv = input.uv;
    output.col = input.col;
    return output;
}

float4 PSMain(VSOutput input) : SV_Target {
    return input.col;
}

// int PSMain() : SV_Target {
//     return 1;
// }

float4 PSMain(float2 uv : TEXCOORD_INVALID) : SV_Target {
    return float4(1,0,0,1);
}

[shader("compute")]
[numthreads(8, 1, 1)]
void CSMain(uint3 threadID : SV_DispatchThreadID) {
}

