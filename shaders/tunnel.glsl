// The demoscene tunnel: a cylinder unrolled by polar coordinates, with a grid
// on the inside of it and a camera that sways as it flies.
//
// Stateless by construction, like every shader here. Nothing is traced and
// nothing is stored: the angle around the middle of the screen is the way
// round the cylinder, one over the distance from the middle is the way down
// it, and iTime slides the second one.

const float PANELS = 16.0;        // panels around the tunnel, must be a whole
                                  // number or the seam at the back would show
const float RINGS = 2.6;          // rings per unit of depth
const float FLY_SPEED = 0.85;     // depth units per second
const float TWIST = 0.055;        // how much the tunnel corkscrews
const float SWAY = 0.11;          // how far the camera wanders, in screen heights

const vec3 SEAM_COLOR = vec3(0.35, 0.95, 1.00);
const vec3 PANEL_COLOR = vec3(0.045, 0.075, 0.21);

vec3 palette(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.28, 0.55)));
}

// Distance to the nearest edge of a cell, in cells.
float toEdge(float x) {
    float f = fract(x);
    return min(f, 1.0 - f);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // The camera wanders instead of staring straight down the middle, which is
    // what stops the tunnel from looking like a still image with a moving
    // texture on it.
    vec2 drift = vec2(sin(iTime * 0.31), sin(iTime * 0.23 + 1.7)) * SWAY;
    vec2 p = (fragCoord - 0.5 * iResolution.xy) / iResolution.y - drift;

    float radius = max(length(p), 1e-4);
    float around = atan(p.y, p.x) * 0.15915494;   // 1/(2*pi)

    // Straight down the tunnel. Depth is one over the radius, which is what
    // perspective does to a cylinder seen from inside.
    float depth = 0.34 / radius + iTime * FLY_SPEED;
    float twisted = around + depth * TWIST;

    // How much depth one screen pixel covers, so the seams stay the same
    // width whether they are next to the camera or far down the tunnel.
    float pixel = 1.0 / iResolution.y;
    float ringSpan = 0.34 / (radius * radius) * pixel * RINGS;
    float panelSpan = pixel / radius * 0.15915494 * PANELS;

    float ring = toEdge(depth * RINGS);
    float panel = toEdge(twisted * PANELS);

    float seam = max(
        1.0 - smoothstep(ringSpan * 0.6, ringSpan * 1.8, ring),
        1.0 - smoothstep(panelSpan * 0.6, panelSpan * 1.8, panel)
    );

    // Every other panel is filled, so the tunnel reads as a surface rather
    // than as a wireframe hanging in space.
    float checker = mod(floor(depth * RINGS) + floor(twisted * PANELS), 2.0);

    vec3 hue = palette(depth * 0.06 + iTime * 0.02);
    vec3 color = mix(PANEL_COLOR * 0.30, PANEL_COLOR, checker);
    color += mix(SEAM_COLOR, hue, 0.55) * seam * 1.25;

    // Fog: far down the tunnel is near the middle of the screen, and dark.
    float fog = smoothstep(0.0, 0.42, radius);
    color *= fog;

    // ...and the very middle keeps a little glow, so it reads as a tunnel
    // running away rather than as a hole.
    color += mix(SEAM_COLOR, hue, 0.5) * 0.20 * exp(-radius * 8.0);

    fragColor = vec4(color, 1.0);
}
