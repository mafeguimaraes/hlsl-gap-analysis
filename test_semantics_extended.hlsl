struct PSOutput_MultiTarget {
    float4 color0 : SV_Target0;   
    float4 color1 : SV_Target1;  
};

PSOutput_MultiTarget PS_MultiTarget(float2 uv : TEXCOORD0) {
    PSOutput_MultiTarget o;
    o.color0 = float4(1, 0, 0, 1);
    o.color1 = float4(0, 1, 0, 1);
    return o;
}

struct VSInput_MultiUV {
    float3 pos     : POSITION;
    float2 uv0     : TEXCOORD0;
    float2 uv1     : TEXCOORD1;
    float2 uv2     : TEXCOORD2;
};

struct VSOutput_MultiUV {
    float4 pos     : SV_Position;
    float2 uv0     : TEXCOORD0;
    float2 uv1     : TEXCOORD1;
};

VSOutput_MultiUV VS_MultiUV(VSInput_MultiUV input) {
    VSOutput_MultiUV o;
    o.pos = float4(input.pos, 1.0);
    o.uv0 = input.uv0;
    o.uv1 = input.uv1;
    return o;
}

struct GBuffer {
    float4 albedo   : SV_Target0;
    float4 normal   : SV_Target1;
    float4 position : SV_Target2;
};

GBuffer PS_Deferred(float2 uv : TEXCOORD0) {
    GBuffer g;
    g.albedo   = float4(0.5, 0.5, 0.5, 1.0);
    g.normal   = float4(0.0, 1.0, 0.0, 0.0);
    g.position = float4(0.0, 0.0, 0.0, 1.0);
    return g;
}

struct ClipDistances {
    float4 pos   : SV_Position;
    float  clip0 : SV_ClipDistance0;
    float  clip1 : SV_ClipDistance1;
};

ClipDistances VS_Clip(float3 pos : POSITION) {
    ClipDistances o;
    o.pos   = float4(pos, 1.0);
    o.clip0 = pos.y;     
    o.clip1 = 1.0 - pos.y;
    return o;
}

struct BadSemantic {
    float4 color : SV_Target8; 
};
