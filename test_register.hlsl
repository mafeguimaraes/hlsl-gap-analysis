Texture2D<float4> myTex : register(t0);

RWTexture2D<float4> myRWTex : register(u0)

[shader("compute")]
[numthreads(8,1,1)]
void entry() {}
