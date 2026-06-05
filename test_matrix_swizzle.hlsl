void test_matrix_subscript() {
    float4x4 m = (float4x4)0;

    float4 row0   = m[0];        
    float  elem   = m[0][1];     
    float3 partial = m[1].xyz;   
}

void test_matrix_swizzle_m_notation() {
    float4x4 m = (float4x4)1;

    float  a = m._m00;              // single element
    float2 b = m._m00_m11;          // diagonal (two elements)
    float4 c = m._m00_m11_m22_m33;  // main diagonal (four elements)
    float3 d = m._m01_m02_m03;      // first row, columns 1-3
}

void test_matrix_swizzle_1indexed() {
    float3x3 m = (float3x3)1;

    float  a = m._11;          // row 1, col 1 (same as _m00)
    float2 b = m._11_22;       // diagonal
    float3 c = m._11_22_33;    // full diagonal
}

void test_nonsquare_matrix_swizzle() {
    float3x2 m = (float3x2)0;  // 3 rows, 2 columns

    float  a = m._m00;          // valid
    float  b = m._m21;          // valid: row 2, col 1
    float2 c = m._m00_m01;      // both elements of row 0

    float4 d = m._m00_m01_m10_m11;
}

void test_invalid_swizzle() {
    float2x2 m = (float2x2)0;
    float bad = m._m22;   // out of bounds for 2x2 matrix — should error
}

float4x4 test_swizzle_in_expr(float4x4 a, float4x4 b) {
    float diag_sum = a._m00 + a._m11 + a._m22 + a._m33;
    return b * diag_sum;
}
