// Shared hash functions. This file is prepended to every shader in shaders/
// by Scripts/build-shaders.sh, so a shader calls these without declaring
// them. What a shader does not reference never reaches the MSL - glslang and
// spirv-cross drop unreferenced functions - so an unused helper here costs
// nothing in Generated/Shaders.swift.
//
// The same body throughout, the classic sin-dot fold. It is not a good hash,
// but it is the one every shader here was written against, and changing it
// would change what they draw.

float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float hash31(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453123);
}
