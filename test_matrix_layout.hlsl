row_major float4x4 matA;
column_major float4x4 matB;

[shader("compute")]
[numthreads(8,1,1)]
void entry() {}