Texture2D<float4> tex2d;
RWTexture2D<float4> rwTex;

// Texture2D myTex : register(t0);
// RWTexture2D<float4> myRWTex : register(u0)

StructuredBuffer<float4> structBuf;
RWStructuredBuffer<float4> rwStructBuf;

SamplerState sampler0;

cbuffer Constants {
    float4 color;
    float time;
}

// cbuffer A : register(b0) { float x; }
// cbuffer B : register(b0) { float y; } 

ConstantBuffer<Constants> cb : register(b0);

[numthreads(8,1,1)]
void entry() {}