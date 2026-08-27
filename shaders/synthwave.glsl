// The retro grid: a banded sun on the horizon, a neon lattice running away
// underneath it, and a sky full of haze.
//
// Stateless by construction, like every shader here. The grid is the same
// inverted projection the crawl uses - one over the distance below the horizon
// is the distance away - and the lines are placed by rounding that, not by
// stepping anything forward.
//
// Grid lines are widened by the derivative of the projection so that they stay
// the same thickness on screen wherever they are. Without that the near ones
// are slabs and the far ones alias into a shimmer.

const float HORIZON = 0.06;       // above the middle, in screen heights
const float DEPTH = 0.34;         // sets how quickly the grid runs away
const float RUN_SPEED = 0.55;     // grid squares per second, towards the camera
const float LINE_PX = 1.6;        // grid line thickness in pixels

const float SUN_RADIUS = 0.30;
const float SUN_BANDS = 9.0;      // slots cut across the lower half of the sun

const vec3 SKY_TOP = vec3(0.03, 0.01, 0.10);
const vec3 SKY_LOW = vec3(0.32, 0.04, 0.34);
const vec3 SUN_TOP = vec3(1.00, 0.87, 0.32);
const vec3 SUN_LOW = vec3(1.00, 0.16, 0.46);
const vec3 GRID_COLOR = vec3(0.30, 1.00, 0.95);
const vec3 GROUND = vec3(0.05, 0.01, 0.09);

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Distance to the nearest line of a unit lattice, in lattice units.
float toLine(float x) {
    float f = fract(x);
    return min(f, 1.0 - f);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin in the middle, y upward. fragCoord grows downward
    // here and in Ghostty alike, so it is flipped once, here.
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.y = -uv.y;
    float pixel = 1.0 / iResolution.y;

    vec3 color;

    if (uv.y > HORIZON) {
        // Sky: a gradient, a few stars, and the sun sitting on the horizon.
        float up = uv.y - HORIZON;
        color = mix(SKY_LOW, SKY_TOP, smoothstep(0.0, 0.55, up));

        vec2 cell = floor(fragCoord / (iResolution.y / 40.0));
        float seed = hash21(cell);
        if (seed < 0.10) {
            vec2 inCell = fract(fragCoord / (iResolution.y / 40.0));
            vec2 at = vec2(hash21(cell + 3.7), hash21(cell + 9.1));
            float star = exp(-dot(inCell - at, inCell - at) * 260.0);
            color += vec3(0.9, 0.85, 1.0) * star * smoothstep(0.0, 0.35, up) * 0.9;
        }

        // The sun. Its lower half is cut into slots, narrower towards the
        // bottom, which is the whole of the look.
        vec2 toSun = vec2(uv.x, up - SUN_RADIUS * 0.42);
        float sun = length(toSun);
        float inSun = 1.0 - smoothstep(SUN_RADIUS - pixel * 2.0, SUN_RADIUS, sun);
        if (inSun > 0.0) {
            float down = (SUN_RADIUS * 0.42 - up) / SUN_RADIUS;   // 0 at the middle, 1 at the foot
            float slot = 0.0;
            if (down > 0.0) {
                float band = toLine(down * SUN_BANDS);
                // The slots open up towards the bottom of the disc.
                slot = 1.0 - smoothstep(0.0, mix(0.05, 0.40, down / 0.42), band);
            }
            vec3 face = mix(SUN_LOW, SUN_TOP, smoothstep(-SUN_RADIUS, SUN_RADIUS, toSun.y));
            color = mix(color, face, inSun * (1.0 - slot));
        }
        // Haze around the sun, whether or not this pixel is on it.
        color += mix(SUN_LOW, SUN_TOP, 0.4) * 0.30 * exp(-sun * 5.0);
    } else {
        // Ground: invert the projection to get grid coordinates, then draw the
        // lattice with a thickness measured in screen pixels.
        float below = HORIZON - uv.y;
        float depth = DEPTH / below;
        float across = uv.x * depth / DEPTH;
        float along = depth - iTime * RUN_SPEED;

        // How far one screen pixel reaches in each grid direction.
        float spanAcross = depth / DEPTH * pixel;
        float spanAlong = depth * depth / DEPTH * pixel;

        // Once a screen pixel spans a good part of a grid square that family
        // of lines is past resolving, and drawing it anyway paints a solid
        // slab along the horizon. The two families give out at different
        // depths - one span grows with the distance, the other with its square
        // - so each fades on its own.
        float halfWidth = LINE_PX * 0.5;
        float line = max(
            (1.0 - smoothstep(spanAcross * halfWidth, spanAcross * (halfWidth + 1.0), toLine(across)))
                * (1.0 - smoothstep(0.10, 0.32, spanAcross)),
            (1.0 - smoothstep(spanAlong * halfWidth, spanAlong * (halfWidth + 1.0), toLine(along)))
                * (1.0 - smoothstep(0.10, 0.32, spanAlong))
        );

        color = GROUND;
        // The grid fades all the way out with distance rather than settling on
        // a dim floor: a dim floor is still a picket fence of lines packed
        // tighter than the pixels, and that reads as a band of speckle.
        float reach = 1.0 - smoothstep(3.5, 13.0, depth);
        color += GRID_COLOR * line * reach;
        // Neon spill on the ground itself.
        color += GRID_COLOR * 0.05 * reach;
        color += SUN_LOW * 0.20 * exp(-below * 6.0);
    }

    // A soft line along the horizon so the two halves meet on something.
    color += mix(SUN_LOW, GRID_COLOR, 0.30) * 0.45 * exp(-abs(uv.y - HORIZON) * 520.0);

    fragColor = vec4(color, 1.0);
}
