// Conversion smoke test: Shadertoy form, mainImage only.
//
// Also the demonstration of shaders/lib/dither.glsl: the gradient goes out
// through the RGB555 quantise and Bayer dither, so 32 levels per channel is
// what a frame of it contains.
//
// And of shaders/lib/palette.glsl: the middle of the frame is washed with
// the sky role for the time of day in iDate, so a frame of the fixture at
// noon is not a frame of it at midnight. The wash is exactly zero outside a
// disc around the centre, which leaves the corners the tests read as the
// plain ramps they have always been.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    float pulse = 0.5 + 0.5 * sin(iTime * 2.0);
    vec3 color = vec3(uv.x, uv.y, pulse);
    float wash = 1.0 - smoothstep(0.0, 0.35, length(uv - 0.5));
    color = mix(color, paletteColor(ROLE_SKY, dayPhase()), wash * 0.6);
    fragColor = vec4(dither555(color, fragCoord), 1.0);
}
