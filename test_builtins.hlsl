float4 entry() {
    float3 v1 = float3(1, 0, 0);
    float3 v2 = float3(0, 1, 0);
    
    float d = dot(v1, v2);
    float3 l = lerp(v1, v2, float3(0.5));
    float3 n = normalize(v1);
    float3 s = saturate(v1);
    
    float4x4 mat1;
    float4x4 mat2;
    float4x4 m = mul(mat1, mat2);

    return float4(l, 1.0);
}

float wrong_dot() {
    float4x4 mat;
    float3 v;
    return dot(mat, v); 
}

Texture2D<float4> tex2d : register(t0);
RWTexture2D<float4> rwTex : register(u0);
SamplerState samp : register(s0);

float4 test_sample(float2 uv : TEXCOORD) : SV_Target {
    return tex2d.Sample(samp, uv);
}

float4 test_load() : SV_Target {
    int3 coords = int3(10, 20, 0); 
    return tex2d.Load(coords);
}

void test_store(uint2 coords : SV_DispatchThreadID) {
    rwTex[coords] = float4(1.0, 0.0, 0.0, 1.0);
    tex2d[uint2(0,0)] = float4(1,0,0,1);
}

//tex2d.