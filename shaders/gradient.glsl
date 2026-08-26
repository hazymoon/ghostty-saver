// Conversion smoke test: Shadertoy form, mainImage only.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float pulse = 0.5 + 0.5 * sin(iTime * 2.0);
    fragColor = vec4(uv.x, uv.y, pulse, 1.0);
}
