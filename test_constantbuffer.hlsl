struct MyConstants {
    float4 color;
    float time;
};

ConstantBuffer<MyConstants> cb : register(b0);

[shader("compute")]
[numthreads(8,1,1)]
void entry() {}
