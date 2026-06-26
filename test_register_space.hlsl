Texture2D <float4> tex0 : register(t0, space0);   // SRV, default space
Texture2D<float4>  tex1 : register(t0, space1);   // SRV, same slot, different space
RWTexture2D<float4> rw0  : register(u0, space0);   // UAV
SamplerState samp : register(s0, space2);   // Sampler

cbuffer Constants : register(b0, space0) {
    float4 color;
}

cbuffer LightData : register(b0, space1) {
    float3 lightDir;
    float  intensity;
}

StructuredBuffer<float4>   inputData  : register(t1, space0);
RWStructuredBuffer<float4> outputData : register(u1, space0);

[numthreads(1, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID) {
    float4 val = inputData[tid.x];
    outputData[tid.x] = val * color;
}
