void paramTest(in float a, out float b, inout float c) {
    b = a;
    c = a + c;
}

[shader("compute")]
[numthreads(8,1,1)]
void entry() {}
 