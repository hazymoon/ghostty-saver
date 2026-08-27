// The opening crawl: yellow text receding towards a vanishing point over a
// field of stars.
//
// Stateless by construction, like every shader here. The crawl is a plane in
// perspective, so a pixel is turned into a text coordinate by inverting the
// projection rather than by moving anything: screen position and iTime go in,
// a line and a column come out.
//
// Text needs letterforms, and there is no font atlas on this path, so the
// alphabet is a 5x6 bitmap packed one glyph per uint and the crawl itself is
// packed four characters per uint. Both tables are generated from readable
// source; the comment on each line is what it says.
//
// The crawl loops: line numbers are taken modulo CRAWL_LINES + GAP_LINES, so
// the text runs, the screen empties, and it begins again.

const int COLS = 28;              // columns per line, the crawl is padded to it
const int GAP_LINES = 9;          // empty lines between one run and the next

const float HORIZON = 0.42;       // where the plane vanishes, in screen heights
const float DEPTH = 11.0;         // depth of the bottom edge, in line heights
// The width the depth above was chosen against. A narrower window pushes the
// plane further away by the shortfall, so the same COLS columns still fit
// across it rather than running off both sides; a wider one is left alone and
// gets margins instead.
const float REFERENCE_ASPECT = 16.0 / 9.0;
const float CELL_ASPECT = 0.75;   // character advance / line height
const float LINE_SECONDS = 6.4;   // how long one line takes to climb one line
// How far back the text reaches, in line heights past the bottom edge of the
// screen. Measured from that edge rather than from the camera, so the same
// fourteen lines are in view whatever shape the window is. A threshold fixed
// in depth instead would grow with the stretch below, and a tall enough window
// would then hold more lines at once than the loop has, showing the same line
// twice.
const float FADE_FROM = 7.0;
const float FADE_TO = 14.0;

// The glyph sits inside its cell: 5x6 lit bits inside a 6x8 advance.
const vec2 GLYPH_ORIGIN = vec2(1.0 / 12.0, 1.0 / 8.0);
const vec2 GLYPH_SIZE = vec2(5.0 / 6.0, 6.0 / 8.0);

const vec3 CRAWL_COLOR = vec3(1.00, 0.87, 0.13);
const vec3 STAR_COLOR = vec3(0.85, 0.90, 1.00);
const float STAR_ROWS = 42.0;     // rows of candidate stars down the screen
const float STAR_DENSITY = 0.24;  // fraction of cells holding one

// A glyph is 30 bits: bit (row * 5 + column), row 0 at the top, column 0 at
// the left. The art in each comment is the glyph the number spells out.
const uint LETTERS[26] = uint[26](
    0x231FC62Eu,   // A  .###./#...#/#...#/#####/#...#/#...#
    0x1F18BE2Fu,   // B  ####./#...#/####./#...#/#...#/####.
    0x1D10862Eu,   // C  .###./#...#/#..../#..../#...#/.###.
    0x1F18C62Fu,   // D  ####./#...#/#...#/#...#/#...#/####.
    0x3E10BC3Fu,   // E  #####/#..../####./#..../#..../#####
    0x210BC3Fu,   // F  #####/#..../####./#..../#..../#....
    0x1D1C862Eu,   // G  .###./#...#/#..../#..##/#...#/.###.
    0x2318FE31u,   // H  #...#/#...#/#####/#...#/#...#/#...#
    0x3E42109Fu,   // I  #####/..#../..#../..#../..#../#####
    0x1D184210u,   // J  ....#/....#/....#/....#/#...#/.###.
    0x22929D31u,   // K  #...#/#..#./###../#.#../#..#./#...#
    0x3E108421u,   // L  #..../#..../#..../#..../#..../#####
    0x2318D771u,   // M  #...#/##.##/#.#.#/#...#/#...#/#...#
    0x231CD671u,   // N  #...#/##..#/#.#.#/#..##/#...#/#...#
    0x1D18C62Eu,   // O  .###./#...#/#...#/#...#/#...#/.###.
    0x217C62Fu,   // P  ####./#...#/#...#/####./#..../#....
    0x2C9AC62Eu,   // Q  .###./#...#/#...#/#.#.#/#..#./.##.#
    0x2297C62Fu,   // R  ####./#...#/#...#/####./#..#./#...#
    0x1F08383Eu,   // S  .####/#..../.###./....#/....#/####.
    0x842109Fu,   // T  #####/..#../..#../..#../..#../..#..
    0x1D18C631u,   // U  #...#/#...#/#...#/#...#/#...#/.###.
    0x8A8C631u,   // V  #...#/#...#/#...#/#...#/.#.#./..#..
    0x23BAC631u,   // W  #...#/#...#/#...#/#.#.#/##.##/#...#
    0x22A21151u,   // X  #...#/.#.#./..#../..#../.#.#./#...#
    0x8421151u,   // Y  #...#/.#.#./..#../..#../..#../..#..
    0x3E22221Fu   // Z  #####/....#/...#./..#../.#.../#####
);

const uint GLYPH_STOP = 0x8000000u;   // .  ...../...../...../...../...../..#..
const uint GLYPH_COMMA = 0x4400000u;   // ,  ...../...../...../...../..#../.#...
const uint GLYPH_TICK = 0x0000084u;   // '  ..#../..#../...../...../...../.....
const uint GLYPH_DASH = 0x00F8000u;   // -  ...../...../...../#####/...../.....
const uint GLYPH_BANG = 0x8021084u;   // !  ..#../..#../..#../..#../...../..#..
const uint GLYPH_QUERY = 0x802222Eu;   // ?  .###./#...#/...#./..#../...../..#..

// 17 lines of 28 columns, 119 words.
const int CRAWL_LINES = 17;
const uint CRAWL[119] = uint[119](
    0x20202020u, 0x20202020u, 0x49504520u, 0x45444F53u, 0x20564920u, 0x20202020u, 0x20202020u,   // EPISODE IV
    0x20202020u, 0x41202020u, 0x57454E20u, 0x53455320u, 0x4E4F4953u, 0x20202020u, 0x20202020u,   // A NEW SESSION
    0x20202020u, 0x20202020u, 0x20202020u, 0x20202020u, 0x20202020u, 0x20202020u, 0x20202020u,   // .
    0x54492020u, 0x20534920u, 0x45502041u, 0x444F4952u, 0x20464F20u, 0x45495551u, 0x20202054u,   // IT IS A PERIOD OF QUIET
    0x44492020u, 0x474E494Cu, 0x4854202Eu, 0x45542045u, 0x4E494D52u, 0x48204C41u, 0x20205341u,   // IDLING. THE TERMINAL HAS
    0x45454220u, 0x4F4C204Eu, 0x44454B43u, 0x4854202Cu, 0x454B2045u, 0x414F4259u, 0x20204452u,   // BEEN LOCKED, THE KEYBOARD
    0x20534920u, 0x4C495453u, 0x41202C4Cu, 0x4E20444Eu, 0x4F20544Fu, 0x4B20454Eu, 0x20205945u,   // IS STILL, AND NOT ONE KEY
    0x53414820u, 0x45454220u, 0x5453204Eu, 0x4B435552u, 0x524F4620u, 0x4E4F4C20u, 0x20524547u,   // HAS BEEN STRUCK FOR LONGER
    0x4E414854u, 0x594E4120u, 0x20454E4Fu, 0x45524143u, 0x4F542053u, 0x4D444120u, 0x202E5449u,   // THAN ANYONE CARES TO ADMIT.
    0x20202020u, 0x20202020u, 0x20202020u, 0x20202020u, 0x20202020u, 0x20202020u, 0x20202020u,   // .
    0x45454420u, 0x4E492050u, 0x45444953u, 0x45485420u, 0x43414D20u, 0x454E4948u, 0x20204120u,   // DEEP INSIDE THE MACHINE A
    0x41524620u, 0x4E454D47u, 0x48532054u, 0x52454441u, 0x494F5420u, 0x4F20534Cu, 0x20202C4Eu,   // FRAGMENT SHADER TOILS ON,
    0x4E494150u, 0x474E4954u, 0x58495020u, 0x20534C45u, 0x54414854u, 0x204F4E20u, 0x20454E4Fu,   // PAINTING PIXELS THAT NO ONE
    0x53492020u, 0x45485420u, 0x54204552u, 0x4553204Fu, 0x57202C45u, 0x49544941u, 0x2020474Eu,   // IS THERE TO SEE, WAITING
    0x524F4620u, 0x45485420u, 0x554F5420u, 0x4F204843u, 0x20412046u, 0x474E4953u, 0x2020454Cu,   // FOR THE TOUCH OF A SINGLE
    0x4B202020u, 0x54205945u, 0x4553204Fu, 0x48542054u, 0x45532045u, 0x4F495353u, 0x2020204Eu,   // KEY TO SET THE SESSION
    0x20202020u, 0x46202020u, 0x20454552u, 0x49414741u, 0x2E2E2E4Eu, 0x20202020u, 0x20202020u   // FREE AGAIN...
);

float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

uint glyphBits(uint code) {
    if (code >= 65u && code <= 90u) { return LETTERS[int(code) - 65]; }
    if (code == 46u) { return GLYPH_STOP; }
    if (code == 44u) { return GLYPH_COMMA; }
    if (code == 39u) { return GLYPH_TICK; }
    if (code == 45u) { return GLYPH_DASH; }
    if (code == 33u) { return GLYPH_BANG; }
    if (code == 63u) { return GLYPH_QUERY; }
    return 0u;
}

// 1 where the crawl has ink at that column and line, 0 where it does not.
// Fractional parts pick out the bit inside the character cell.
float ink(float column, float line) {
    float wrapped = mod(floor(line), float(CRAWL_LINES + GAP_LINES));
    if (wrapped >= float(CRAWL_LINES)) { return 0.0; }

    int col = int(floor(column));
    if (col < 0 || col >= COLS) { return 0.0; }

    int index = int(wrapped) * COLS + col;
    uint word = CRAWL[index >> 2];
    uint code = (word >> (uint(index & 3) * 8u)) & 0xFFu;

    uint bits = glyphBits(code);
    if (bits == 0u) { return 0.0; }

    vec2 inner = (vec2(fract(column), fract(line)) - GLYPH_ORIGIN) / GLYPH_SIZE;
    // Half-open on the top end: an inner that rounds to exactly 1.0 would put
    // the bit index at (5, 6) and the shift at 35, past the width of bits.
    if (inner.x < 0.0 || inner.x >= 1.0 || inner.y < 0.0 || inner.y >= 1.0) { return 0.0; }

    ivec2 bit = ivec2(floor(inner * vec2(5.0, 6.0)));
    return float((bits >> uint(bit.y * 5 + bit.x)) & 1u);
}

vec3 starfield(vec2 fragCoord) {
    // Cells sized off the screen rather than fixed in pixels, so a denser
    // display gets bigger cells instead of four times as many stars.
    float cellSize = iResolution.y / STAR_ROWS;
    vec2 grid = fragCoord / cellSize;
    vec2 cell = floor(grid);
    float seed = hash21(cell);
    if (seed > STAR_DENSITY) { return vec3(0.0); }

    vec2 position = vec2(hash11(seed * 13.7), hash11(seed * 29.3));
    float away = length((fract(grid) - position) * cellSize);
    float brightness = 0.30 + 0.70 * hash11(seed * 7.1);
    float twinkle = 0.78 + 0.22 * sin(iTime * (0.6 + 1.8 * hash11(seed * 3.3)) + seed * 90.0);
    return STAR_COLOR * exp(-away * away / 0.42) * brightness * twinkle;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // Screen heights, origin in the middle, y upward: fragCoord grows downward
    // here and in Ghostty alike, so it is flipped once, here.
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    uv.y = -uv.y;

    vec3 color = starfield(fragCoord);

    float below = HORIZON - uv.y;
    if (below > 0.0) {
        // Inverting the projection: a pixel this far below the vanishing point
        // is looking at the plane this many line heights away.
        float aspect = min(iResolution.x / iResolution.y, REFERENCE_ASPECT);
        float stretch = REFERENCE_ASPECT / aspect;   // 1.0 at the reference width, more when narrower
        float depth = DEPTH * stretch / below;
        // The bottom edge of the screen sits at uv.y = -0.5, and that is where
        // the visible run of text starts.
        float nearest = DEPTH * stretch / (HORIZON + 0.5);

        // Scrolling by whole loops of the crawl rather than by iTime keeps the
        // numbers small however long the screensaver runs, and the loop period
        // is exactly one pass of the text, so the wrap is invisible.
        float loop = float(CRAWL_LINES + GAP_LINES) * LINE_SECONDS;
        float scrolled = mod(iTime, loop) / LINE_SECONDS;

        float line = scrolled - depth;
        float column = uv.x * depth / CELL_ASPECT + float(COLS) * 0.5;

        // How much text one screen pixel covers, from the derivatives of the
        // two lines above. Near the vanishing point this grows without bound,
        // which is what the sampling below has to cope with.
        float pixel = 1.0 / iResolution.y;
        float spanX = depth / CELL_ASPECT * pixel;
        float spanY = depth * depth / (DEPTH * stretch) * pixel;

        // Four taps across that footprint: enough to keep the near text from
        // crawling with jaggies.
        float cover = ink(column - spanX * 0.25, line - spanY * 0.25)
            + ink(column + spanX * 0.25, line - spanY * 0.25)
            + ink(column - spanX * 0.25, line + spanY * 0.25)
            + ink(column + spanX * 0.25, line + spanY * 0.25);
        cover *= 0.25;

        // The text fades out with distance the way it does in the film,
        // counted from the near edge so the run is the same length on any
        // window.
        float faded = 1.0 - smoothstep(nearest + FADE_FROM, nearest + FADE_TO, depth);
        // On a screen too coarse to resolve the glyphs that far back, fade
        // sooner: past the point where one pixel covers most of a glyph row no
        // amount of sampling helps and the text would only shimmer. One glyph
        // row is an eighth of a line, so the thresholds are fractions of that.
        float legible = 1.0 - smoothstep(0.050, 0.140, spanY);
        color = mix(color, CRAWL_COLOR, cover * min(faded, legible));
    }

    fragColor = vec4(color, 1.0);
}
