// Saturn: banded globe, rings cut by the Cassini division, and the shadow the
// planet throws across them, slowly turning under a thin field of stars.
//
// Stateless by construction, like every shader here. Nothing is marched: the
// globe is one ray-sphere intersection in closed form and the rings are one
// ray-plane intersection, and the two are composited by depth. Ring structure
// is a function of radius alone, so a pixel on the ring plane asks its radius
// and reads a small table of gaps. The planet's shadow on the rings is the
// projection of the sphere along the light direction, which is one distance
// test against a cylinder. The whole system tilts and turns on iTime.
//
// At a shallow view angle a screen pixel covers a wide stretch of ring, so the
// gap detail fades out where its on-screen radial spacing gets too tight -
// the same minification treatment the projection shaders use.

const float PLANET_RADIUS = 1.0;
const float RING_INNER = 1.24;      // C ring starts here
const float RING_C_END = 1.53;      // C ring, faint
const float RING_B_END = 1.95;      // B ring, bright, ends at the Cassini division
const float CASSINI_END = 2.02;
const float RING_OUTER = 2.27;      // A ring
const float ENCKE = 2.21;           // a narrow gap in the A ring

const float CAMERA_DISTANCE = 6.2;
const float VIEW_HEIGHT = 1.75;     // half height of the view at the planet, in world units
const float TURN_RATE = 0.045;      // radians per second, the whole system turning
const float TILT_BASE = 0.42;       // radians, ring plane against the view
const float TILT_SWAY = 0.10;

const vec3 LIGHT_DIR = normalize(vec3(-0.65, 0.35, 0.68));
const vec3 SKY = vec3(0.004, 0.005, 0.010);
const vec3 BAND_CREAM = vec3(0.93, 0.86, 0.66);
const vec3 BAND_TAN = vec3(0.78, 0.66, 0.44);
const vec3 BAND_OCHRE = vec3(0.62, 0.48, 0.28);
const vec3 RING_COLOR = vec3(0.86, 0.80, 0.66);

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Ring opacity as a function of radius, before lighting. Zero outside.
float ringDensity(float r, float blur) {
    float inside = smoothstep(RING_INNER - blur, RING_INNER + blur, r)
                 * (1.0 - smoothstep(RING_OUTER - blur, RING_OUTER + blur, r));
    if (inside <= 0.0) return 0.0;

    // C ring faint, B ring dense and brightest at its outer edge, A ring middling.
    float c = 0.22 * smoothstep(RING_INNER, RING_INNER + 0.08, r);
    float b = 0.95;
    float a = 0.62;
    float density = c;
    density = mix(density, b, smoothstep(RING_C_END - blur, RING_C_END + blur, r));
    density = mix(density, a, smoothstep(RING_B_END - blur, RING_B_END + blur, r));

    // Fine ringlets, faded with the gaps when the view is too shallow to resolve them.
    float ringlets = 0.5 + 0.5 * sin(r * 110.0) * sin(r * 37.0 + 1.3);
    density *= mix(1.0, 0.72 + 0.28 * ringlets, 1.0 - smoothstep(0.004, 0.02, blur));

    // The gaps. Cassini is the wide one; Encke is narrow.
    float cassini = smoothstep(RING_B_END - blur, RING_B_END + blur, r)
                  * (1.0 - smoothstep(CASSINI_END - blur, CASSINI_END + blur, r));
    float encke = smoothstep(ENCKE - 0.012 - blur, ENCKE - 0.012 + blur, r)
                * (1.0 - smoothstep(ENCKE + 0.012 - blur, ENCKE + 0.012 + blur, r));
    // A gap narrower than the pixel fades to a dim band rather than vanishing.
    float gapDepth = 1.0 - smoothstep(0.01, 0.05, blur);
    density *= 1.0 - cassini * mix(0.55, 0.96, gapDepth);
    density *= 1.0 - encke * 0.85 * gapDepth;

    return density * inside;
}

// Surface colour of the globe at a latitude, as bands with a little wobble.
vec3 bandColor(float latitude, float longitude) {
    float wobble = 0.03 * sin(longitude * 5.0 + latitude * 9.0) + 0.02 * sin(longitude * 11.0 - latitude * 4.0);
    float l = latitude + wobble;
    float bands = 0.5 + 0.5 * sin(l * 14.0) * 0.8 + 0.2 * sin(l * 31.0 + 0.7);
    vec3 color = mix(BAND_TAN, BAND_CREAM, smoothstep(0.35, 0.75, bands));
    color = mix(color, BAND_OCHRE, smoothstep(0.2, 0.0, bands) * 0.7);
    // Polar regions darken and go slightly blue-grey.
    color = mix(color, vec3(0.42, 0.42, 0.40), smoothstep(1.25, 1.55, abs(l)));
    return color;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.y = -uv.y;

    // Orientation of the planet's axis: tilted toward the viewer and slowly
    // turning around the vertical, so the rings open and close and swing.
    float turn = iTime * TURN_RATE;
    float tilt = TILT_BASE + TILT_SWAY * sin(iTime * 0.09);
    float ct = cos(tilt), st = sin(tilt);
    float cy = cos(turn), sy = sin(turn);
    // Axis = R_y(turn) * R_x(tilt) * (0, 1, 0)
    vec3 axis = normalize(vec3(sy * st, ct, -cy * st));

    // Camera on the z axis looking toward the origin.
    vec3 ro = vec3(0.0, 0.0, CAMERA_DISTANCE);
    vec3 rd = normalize(vec3(uv * VIEW_HEIGHT / CAMERA_DISTANCE * 2.0, -1.0));

    // Stars.
    vec3 color = SKY;
    {
        vec2 cell = floor(fragCoord / (iResolution.y / 60.0));
        float seed = hash21(cell);
        if (seed < 0.09) {
            vec2 inCell = fract(fragCoord / (iResolution.y / 60.0));
            vec2 at = vec2(hash21(cell + 3.7), hash21(cell + 9.1));
            float star = exp(-dot(inCell - at, inCell - at) * 320.0);
            color += vec3(0.8, 0.85, 1.0) * star * (0.35 + 0.5 * hash21(cell + 5.5));
        }
    }

    // Ray-sphere: closed form.
    float b = dot(ro, rd);
    float c = dot(ro, ro) - PLANET_RADIUS * PLANET_RADIUS;
    float disc = b * b - c;
    float tPlanet = 1e9;
    if (disc > 0.0) tPlanet = -b - sqrt(disc);

    // Ray-plane through the origin with normal `axis`.
    float denom = dot(rd, axis);
    float tRing = -dot(ro, axis) / denom;
    vec3 ringHit = ro + rd * tRing;
    float r = length(ringHit);
    // How much ring radius one pixel spans: the minification measure.
    // Capped: near edge-on the span is unbounded, and an uncapped blur
    // would smear the ring edges across the whole sky.
    float blur = clamp(fwidth(r) * 0.7, 0.002, 0.12);
    float ringAlpha = 0.0;
    vec3 ringShade = vec3(0.0);
    if (tRing > 0.0 && abs(denom) > 1e-4) {
        ringAlpha = ringDensity(r, blur);
        if (ringAlpha > 0.0) {
            // Shadow: is this ring point inside the cylinder of the planet
            // along the light direction, on the far side of the planet?
            vec3 toLight = ringHit - LIGHT_DIR * dot(ringHit, LIGHT_DIR);
            float lateral = length(toLight);
            float behind = -dot(ringHit, LIGHT_DIR);   // positive when the planet is between point and sun
            float shadow = smoothstep(PLANET_RADIUS - 0.04, PLANET_RADIUS + 0.04, lateral);
            shadow = mix(1.0, shadow, step(0.0, behind));
            // Lit side of the ring plane vs. the unlit side seen through it.
            float facing = dot(axis, LIGHT_DIR) * sign(dot(axis, -rd));
            float light = mix(0.35, 1.0, smoothstep(-0.3, 0.3, facing));
            ringShade = RING_COLOR * (0.12 + 0.88 * shadow * light);
        }
    }

    // Planet shading.
    vec3 planetShade = vec3(0.0);
    float planetAlpha = 0.0;
    if (disc > 0.0) {
        vec3 p = ro + rd * tPlanet;
        vec3 n = p / PLANET_RADIUS;
        float latitude = asin(clamp(dot(n, axis), -1.0, 1.0));
        vec3 east = normalize(cross(axis, vec3(0.0, 0.0, 1.0)));
        vec3 north = cross(east, axis);
        float longitude = atan(dot(n, north), dot(n, east)) + iTime * 0.08;
        vec3 albedo = bandColor(latitude * 1.6, longitude);
        float diffuse = max(dot(n, LIGHT_DIR), 0.0);
        // The rings throw a shadow band onto the globe as well.
        vec3 lateralP = p - LIGHT_DIR * dot(p, LIGHT_DIR);
        float ringShadow = 1.0;
        {
            // Walk the light ray back to the ring plane from this surface point.
            float dl = dot(LIGHT_DIR, axis);
            if (abs(dl) > 1e-3) {
                float tl = -dot(p, axis) / dl;
                if (tl > 0.0) {
                    float rr = length(p + LIGHT_DIR * tl);
                    ringShadow = 1.0 - 0.75 * ringDensity(rr, 0.03);
                }
            }
        }
        float limb = smoothstep(0.0, 0.25, dot(n, -rd));
        planetShade = albedo * (0.02 + diffuse * ringShadow * mix(0.55, 1.0, limb));
        // Edge anti-aliasing from the discriminant.
        planetAlpha = smoothstep(0.0, 0.004, disc);
    }

    // Composite by depth.
    if (planetAlpha > 0.0 && tPlanet < tRing) {
        // Planet in front: rings behind it show only outside its disc.
        color = mix(color, ringShade, ringAlpha);
        color = mix(color, planetShade, planetAlpha);
    } else {
        color = mix(color, planetShade, planetAlpha);
        color = mix(color, ringShade, ringAlpha);
    }

    fragColor = vec4(color, 1.0);
}
