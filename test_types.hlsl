void test_vectors() {
    float2 f2 = float2(1.0, 2.0);
    float3 f3 = float3(1.0, 2.0, 3.0);
    float4 f4 = float4(1.0, 2.0, 3.0, 4.0);
    
    int2 i2 = int2(1, 2);
    int3 i3 = int3(1, 2, 3);
    int4 i4 = int4(1, 2, 3, 4);
    
    float3 swizzle = f4.xyz;
}

void test_matrices() {
    matrix<float, 4, 4> m1;
    
    float4x4 m2;
    
    float val = m2[0][0];
}

// void test_invalid_swizzle() {
//     float2 f2 = float2(1.0, 2.0);
//     float3 invalid = f2.xyz; 
// }

// void test_matrix_access() {
//     float4x4 m2;
//     float val = m2[0][0]; 
//     float val2 = m2[5][0]; 
// }

// void test_type_mismatch() {
//     float3 v = float3(1.0, 2.0, 3.0);
//     int3 i = int3(1, 2, 3);
//     float3 result = v + i; 
// }