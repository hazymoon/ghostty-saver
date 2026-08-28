// The terminal's glyphs cast in bronze: each stroke stands proud of the
// surface, lit from a raking angle, with real depth where one stroke hides
// the foot of the next.
//
// Ghostty custom-shader only. It reads iChannel0, which is the terminal's
// rendered output under Ghostty and a 1x1 black texture in the screensaver,
// so it lives under custom-shaders/ and never enters the catalogue.
//
// The luminance of the terminal image is the height field. It is
// anti-aliased glyph coverage, so it is soft at the edges; a contrast curve
// on it first is what makes the edges read as cast rather than as a soft
// bump. The view ray is tilted by a fixed angle and marched through the
// field in STEPS equal steps - parallax occlusion mapping - so a stroke
// occludes what lies behind it at that angle. The normal is a two-tap
// gradient of the same field, and the material is Blinn-Phong with a warm
// specular over a stone ground with a hash grain.
//
// This is the cast look, not the engraved one: strokes are raised, and each
// keeps a lit top face in the glyph's own colour so it stays readable, which
// is also why it needs no hatching. Cost: STEPS texture fetches per pixel,
// plus two for the normal, on every frame the terminal draws.

const int STEPS = 12;                // marching steps; more is deeper, dearer
const float DEPTH_PX = 6.0;          // relief height, in pixels of parallax
const float TILT = 0.8;              // how much the view leans, 0 is straight down
const float EDGE_LOW = 0.15;         // contrast curve on the coverage
const float EDGE_HIGH = 0.65;
const vec3 LIGHT_DIR = normalize(vec3(-0.7, 0.6, 0.3));
const vec3 STONE = vec3(0.16, 0.15, 0.14);
const vec3 BRONZE = vec3(0.80, 0.55, 0.28);

// The terminal's pixels at a texture coordinate. Everything below goes through
// this so the source of the picture is stated once.
vec3 terminal(vec2 uv) {
    return texture(iChannel0, uv).rgb;
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Height in [0, 1] from the glyph coverage, with the edge sharpened.
float height(vec2 uv) {
    vec3 c = terminal(uv);
    float lum = dot(c, vec3(0.299, 0.587, 0.114));
    return smoothstep(EDGE_LOW, EDGE_HIGH, lum);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 texel = 1.0 / iResolution.xy;

    // The view leans toward the top left, so a raised stroke hides what is
    // just below and right of it. Marching from the surface plane down to
    // the ground, the first step whose height is above the ray is the hit.
    vec2 lean = vec2(-TILT, TILT) * DEPTH_PX * texel;
    vec2 hit = uv;
    float prevH = 1.0;
    float prevRay = 1.0;
    for (int i = 1; i <= STEPS; i++) {
        float ray = 1.0 - float(i) / float(STEPS);   // height of the ray here
        vec2 at = uv + lean * (1.0 - ray);
        float h = height(at);
        if (h >= ray) {
            // Interpolate between this step and the last for a smooth edge.
            float t = (prevRay - prevH) / max((prevRay - prevH) - (ray - h), 1e-4);
            hit = mix(uv + lean * (1.0 - prevRay), at, t);
            break;
        }
        prevH = h;
        prevRay = ray;
        hit = at;
    }

    // Normal from the gradient of the field at the hit.
    float hx = height(hit + vec2(texel.x, 0.0)) - height(hit - vec2(texel.x, 0.0));
    float hy = height(hit + vec2(0.0, texel.y)) - height(hit - vec2(0.0, texel.y));
    // The gradient is per texel, so it is scaled by the relief height in
    // texels to get a slope; without that a 6 px cliff shades like a bump.
    vec3 n = normalize(vec3(-hx * DEPTH_PX * 2.0, -hy * DEPTH_PX * 2.0, 1.0));

    float h = height(hit);
    vec3 glyph = terminal(hit);
    // A raised face keeps the glyph's own colour so the text stays readable;
    // the ground is stone with grain.
    vec3 albedo = mix(STONE * (0.85 + 0.3 * hash21(floor(fragCoord))), glyph * 0.9 + BRONZE * 0.25, h);

    vec3 view = normalize(vec3(-lean * iResolution.xy, DEPTH_PX * 4.0));
    float diffuse = max(dot(n, LIGHT_DIR), 0.0);
    vec3 halfway = normalize(LIGHT_DIR + view);
    float spec = pow(max(dot(n, halfway), 0.0), 36.0);

    vec3 color = albedo * (0.2 + 0.9 * diffuse) + BRONZE * spec * (0.3 + 1.2 * h);
    // A stroke's own shadow: the ground just past a raised edge is darker
    // where the ray came through occluded.
    float occluded = step(0.001, distance(hit, uv)) * (1.0 - h);
    color *= 1.0 - 0.6 * occluded;

    fragColor = vec4(color, 1.0);
}
