// A gravitational lens over the terminal's own text: lines curve inward
// around an invisible mass in the middle of the screen, and text that falls
// past the horizon reddens and goes out.
//
// Ghostty custom-shader only. It reads iChannel0, which is the terminal's
// rendered output under Ghostty and a 1x1 black texture in the screensaver,
// so it lives under custom-shaders/ and never enters the catalogue.
//
// One radial displacement of the sample coordinate before the texture read
// is the whole transform: the deflection falls off as one over the distance
// from the centre, is clamped near it, and is brought to exactly zero at the
// edge of the influence radius so text outside it is the terminal's own
// pixels, untouched. The redshift is a colour transform whose strength is the
// same function of radius. The centre drifts slowly on iTime, which costs
// nothing. Cost: one texture fetch per pixel.

const float INFLUENCE = 0.42;     // radius the lens reaches, in screen heights
const float HORIZON = 0.045;      // radius inside which nothing comes back
const float STRENGTH = 0.012;     // deflection scale; larger bends more
const float RING_WIDTH = 0.012;   // brightening just outside the horizon
const float DRIFT = 0.06;         // how far the centre wanders, in screen heights

// The terminal's pixels at a texture coordinate. Everything below goes through
// this so the source of the picture is stated once.
vec3 terminal(vec2 uv) {
    return texture(iChannel0, uv).rgb;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;

    // Screen heights from the lens centre, with the aspect corrected so the
    // lens is round rather than an ellipse.
    vec2 centre = vec2(0.5, 0.5) + vec2(sin(iTime * 0.13), sin(iTime * 0.09 + 2.0)) * DRIFT
        * vec2(iResolution.y / iResolution.x, 1.0);
    vec2 toCentre = (uv - centre) * vec2(iResolution.x / iResolution.y, 1.0);
    float r = length(toCentre);

    // Outside the influence radius the offset is exactly zero, not merely
    // small: the terminal must stay pixel-exact where the lens does not reach.
    if (r >= INFLUENCE) {
        fragColor = vec4(terminal(uv), 1.0);
        return;
    }

    // Deflection toward the centre, 1/r shaped, tapered to zero at the edge of
    // the influence radius so there is no seam where the transform switches
    // off, and clamped so it cannot blow up at the middle.
    float edge = 1.0 - r / INFLUENCE;
    float falloff = edge * edge;
    float bend = min(STRENGTH / max(r, HORIZON), 0.25) * falloff;
    vec2 direction = toCentre / max(r, 1e-5);
    vec2 displaced = uv - direction * bend * vec2(iResolution.y / iResolution.x, 1.0);

    vec3 color = terminal(displaced);

    // Redshift: pull the blue and green down as light climbs out of the well,
    // strongest at the horizon and zero at the edge.
    float shift = falloff * smoothstep(INFLUENCE, HORIZON, r);
    color *= mix(vec3(1.0), vec3(1.0, 0.35, 0.15), shift);

    // Photon ring: a thin brightening just outside the horizon, then black
    // inside it.
    float ring = 1.0 - smoothstep(0.0, RING_WIDTH, abs(r - HORIZON - RING_WIDTH * 0.5));
    color += vec3(1.0, 0.6, 0.35) * ring * 0.6 * (0.3 + length(color));
    color *= smoothstep(HORIZON - 0.004, HORIZON + 0.004, r);

    fragColor = vec4(color, 1.0);
}
