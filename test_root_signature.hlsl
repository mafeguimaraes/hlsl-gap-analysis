#define RS_CBV "CBV(b0)"

[RootSignature(RS_CBV)]
[numthreads(1, 1, 1)]
void CS_ValidCBV(uint3 tid : SV_DispatchThreadID) {}

[RootSignature("DescriptorTable(SRV(t0), UAV(u0)), StaticSampler(s0)")]
[numthreads(1, 1, 1)]
void CS_ValidComplex(uint3 tid : SV_DispatchThreadID) {}

[RootSignature("INVALID_STRING")]
[numthreads(1, 1, 1)]
void CS_Invalid(uint3 tid : SV_DispatchThreadID) {}

[RootSignature("CBV(b0)")]
float4 PS_WithRootSig(float2 uv : TEXCOORD) : SV_Target {
    return float4(1.0, 0.0, 0.0, 1.0);
}


[RootSignature("CBV(b0, space1)")]
[numthreads(1, 1, 1)]
void CS_WithSpace(uint3 tid : SV_DispatchThreadID) {}
