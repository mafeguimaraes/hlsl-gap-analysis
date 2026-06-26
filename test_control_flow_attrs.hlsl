[numthreads(1, 1, 1)]
void CS_LoopAttrs(uint3 tid : SV_DispatchThreadID) {
    float result = 0.0;

    [loop]
    for (int i = 0; i < 4; i++) {
        result += (float)i;
    }

    [unroll(8)]
    for (int j = 0; j < 8; j++) {
        result += (float)j * 0.1;
    }

    [loop]
    for (int k = 0; k < 16; k++) {
        result += (float)k;
    }
}


[numthreads(1, 1, 1)]
void CS_BranchAttrs(uint3 tid : SV_DispatchThreadID) {
    float val = (float)tid.x;

    [branch]
    if (val > 0.5) {
        val *= 2.0;
    } else {
        val *= 0.5;
    }

    [flatten]
    if (val > 1.0) {
        val = 1.0;
    }

    [branch]
    switch ((int)val) {
        case 0:  val = 0.0; break;
        case 1:  val = 1.0; break;
        default: val = 0.5; break;
    }
}


struct PSInput_Interp {
    float4 pos: SV_Position;

    linear float2 uv0: TEXCOORD0; 
    centroid float2 uv1: TEXCOORD1;
    nointerpolation float4 color: COLOR0;
    noperspective float2 screenUV: TEXCOORD2;
    sample float2 uv2: TEXCOORD3;
};

float4 PS_Interp(PSInput_Interp input) : SV_Target {
    return input.color + float4(input.uv0, 0.0, 1.0);
}

float4 PS_DirectParams(
    linear float4 pos: SV_Position,
    nointerpolation float4 col: COLOR,
    centroid float2 uv: TEXCOORD
) : SV_Target {
    return col;
}

[numthreads(1, 1, 1)]
void CS_BadInterp(nointerpolation float4 val : SV_DispatchThreadID) {}

void bad_unroll() {
    [unroll]
    int x = 5;  
}

