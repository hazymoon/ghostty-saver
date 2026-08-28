// Conversion smoke test: Shadertoy form, mainImage only.
//
// Also the demonstration of shaders/lib/dither.glsl: the gradient goes out
// through the RGB555 quantise and Bayer dither, so 32 levels per channel is
// what a frame of it contains.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float pulse = 0.5 + 0.5 * sin(iTime * 2.0);
    fragColor = vec4(dither555(vec3(uv.x, uv.y, pulse), fragCoord), 1.0);
}
