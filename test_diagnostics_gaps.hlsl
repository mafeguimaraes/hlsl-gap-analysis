// Gap 1

StructuredBuffer<float4>   inputData  : register(t1, space0);
StructuredBuffer<float4>   inputData2  : register(t1, space0); 

// Gap 2

[shader("pixel")]
float4 PS_ValidTarget() : SV_Target0 {  // valid 
    return inputData[0] + inputData2[0];
}

[shader("pixel")]
float4 PS_InvalidTarget() : SV_Target10 { // should error?
    return float4(1.0, 0.0, 0.0, 1.0);
}

