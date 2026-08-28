// The SNES Mode 7 floor: a tiled plane rotating, zooming and scrolling away
// to a horizon under a flat cartoon sky.
//
// Stateless by construction, like every shader here. Below the horizon, one
// over the distance below it is the depth - the same inverted projection the
// crawl and the synthwave grid use - and one affine transform of (x * depth,
// depth), built from iTime, gives a coordinate on the plane. What the plane
// shows is a function of that coordinate alone: a checker, with a coarser
// motif dropped on a hash of tiles, so nothing is stored anywhere.
//
// At the horizon a pixel covers an unbounded stretch of plane, and a checker
// sampled at one point per pixel is noise there. The pattern fades into haze
// as the span of a pixel on the plane grows past what it can resolve, which
// is what the two projection shaders already do with their lines.

const float HORIZON = 0.10;      // above the middle, in screen heights
const float DEPTH = 0.30;        // how quickly the floor runs away
const float TILE = 0.35;         // one checker square, in plane units
const float SCROLL_SPEED = 0.9;  // plane units per second
const float TURN_RATE = 0.16;    // radians per second
const float ZOOM_RATE = 0.11;    // cycles per second of the breathing zoom

const vec3 SKY_TOP = vec3(0.16, 0.30, 0.78);
const vec3 SKY_LOW = vec3(0.62, 0.84, 0.98);
const vec3 HAZE = vec3(0.70, 0.82, 0.92);
const vec3 TILE_A = vec3(0.86, 0.50, 0.24);
const vec3 TILE_B = vec3(0.98, 0.78, 0.44);
const vec3 MOTIF = vec3(0.24, 0.52, 0.30);
const vec3 MOTIF_DOT = vec3(0.92, 0.94, 0.62);

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

mat2 rotation(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat2(c, s, -s, c);
}

// Distance to the nearest edge of a unit lattice, in lattice units.
float toEdge(float x) {
    float f = fract(x);
    return min(f, 1.0 - f);
}

// What the floor shows at plane coordinate p, with span the width of one
// screen pixel there in plane units.
vec3 floorColor(vec2 p, float span) {
    vec2 cell = floor(p / TILE);
    float parity = mod(cell.x + cell.y, 2.0);
    vec3 color = mix(TILE_A, TILE_B, parity);

    // A soft seam between squares, so the checker reads as tiles rather than
    // as a field. Its width is a couple of pixels wherever it is.
    float seam = min(toEdge(p.x / TILE), toEdge(p.y / TILE)) * TILE;
    color *= 1.0 - 0.35 * (1.0 - smoothstep(span * 0.6, span * 1.8, seam));

    // Every fourth-or-so 3x3 block of tiles carries a badge: a green square
    // with a pale dot, placed by a hash of the block. The blocks are coarser
    // than the checker so they survive further out.
    vec2 block = floor(p / (3.0 * TILE));
    if (hash21(block) < 0.22) {
        vec2 inBlock = fract(p / (3.0 * TILE)) - 0.5;
        float badge = max(abs(inBlock.x), abs(inBlock.y));
        float edge = span / (3.0 * TILE);
        float inside = 1.0 - smoothstep(0.30 - edge, 0.30 + edge, badge);
        float dot = 1.0 - smoothstep(0.13 - edge, 0.13 + edge, length(inBlock));
        color = mix(color, MOTIF, inside);
        color = mix(color, MOTIF_DOT, dot);
    }
    return color;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin in the middle, y upward.
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.y = -uv.y;
    float pixel = 1.0 / iResolution.y;

    vec3 color;
    if (uv.y > HORIZON) {
        float up = uv.y - HORIZON;
        color = mix(SKY_LOW, SKY_TOP, smoothstep(0.0, 0.5, up));
    } else {
        float below = HORIZON - uv.y;
        float depth = DEPTH / below;
        vec2 ground = vec2(uv.x * depth / DEPTH, depth);

        // The affine transform: zoom that breathes, a slow turn, and a scroll
        // along the direction of travel. All three are read off iTime.
        float zoom = 1.0 + 0.45 * sin(iTime * ZOOM_RATE * 6.2831853);
        mat2 turn = rotation(iTime * TURN_RATE);
        vec2 plane = turn * (ground * zoom) + vec2(0.0, iTime * SCROLL_SPEED);

        // How far one screen pixel reaches on the plane. Along the view it
        // grows with the square of the depth, across with the depth; the
        // larger of the two is what decides whether a tile still resolves.
        float spanAcross = depth / DEPTH * pixel * zoom;
        float spanAlong = depth * depth / DEPTH * pixel * zoom;
        float span = max(spanAcross, spanAlong);

        color = floorColor(plane, span);

        // Into the haze once a pixel covers a good part of a tile.
        float haze = smoothstep(0.08 * TILE, 0.45 * TILE, span);
        color = mix(color, HAZE, haze);
    }

    // A soft glow along the horizon so the two halves meet on something.
    color = mix(color, HAZE, 0.5 * exp(-abs(uv.y - HORIZON) * 90.0));

    fragColor = vec4(color, 1.0);
}
