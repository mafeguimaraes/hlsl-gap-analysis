//===----------------------------------------------------------------------===//
// Texture types
//===----------------------------------------------------------------------===//

Texture2D<float4> myTex2D : register(t1);

Texture1D<float4> myTex1D : register(t0);

Texture3D<float4> myTex3D : register(t2);
TextureCube<float4> myTexCube : register(t3);

Texture1DArray<float4> myTex1DArray : register(t4);
Texture2DArray<float4> myTex2DArray : register(t5);
TextureCubeArray<float4> myTexCubeArray : register(t6);

Texture2DMS<float4> myTex2DMS : register(t7);
Texture2DMSArray<float4> myTex2DMSArray : register(t8);

//===----------------------------------------------------------------------===//
// RW textures
//===----------------------------------------------------------------------===//

RWTexture1D<float4> myRWTex1D : register(u0);
RWTexture2D<float4> myRWTex2D : register(u1);
RWTexture3D<float4> myRWTex3D : register(u2);

//===----------------------------------------------------------------------===//
// Samplers
//===----------------------------------------------------------------------===//

SamplerState mySampler : register(s0);
SamplerComparisonState myCmpSampler : register(s1);

//===----------------------------------------------------------------------===//
// Buffers
//===----------------------------------------------------------------------===//

RWBuffer<float4> Out : register(u10, space1);

//===----------------------------------------------------------------------===//
// Sample methods
//===----------------------------------------------------------------------===//

float4 testSample(float2 uv, float2 ddx, float2 ddy)
{
    float4 a = myTex2D.Sample(mySampler, uv);
    float4 b = myTex2D.SampleBias(mySampler, uv, 0.5f);
    float4 c = myTex2D.SampleGrad(mySampler, uv, ddx, ddy);
    float4 d = myTex2D.SampleLevel(mySampler, uv, 0);

    return a + b + c + d;
}

//===----------------------------------------------------------------------===//
// Load methods
//===----------------------------------------------------------------------===//

float4 testLoad()
{
    float4 a = myTex1D.Load(int2(0, 0));
    float4 b = myTex2D.Load(int3(0, 0, 0));
    float4 c = myTex3D.Load(int4(0, 0, 0, 0));

    return a + b + c;
}

//===----------------------------------------------------------------------===//
// operator[]
//===----------------------------------------------------------------------===//

float4 testOperator()
{
    float4 a = myTex1D[0];
    float4 b = myTex2D[int2(0, 0)];

    return a + b;
}

//===----------------------------------------------------------------------===//
// RWTexture accesses
//===----------------------------------------------------------------------===//

[numthreads(1,1,1)]
void CSMain(uint3 tid : SV_DispatchThreadID)
{
    myRWTex2D[tid.xy] = float4(1, 2, 3, 4);

    float4 x = myRWTex2D[tid.xy];

    Out[0] = x;
}