#version 300 es
precision highp float;

// ============================================================================
// Raymarched synthwave neon city (Milestone 2).
//
// The whole image is produced by sphere-tracing signed distance fields from the
// camera through every pixel. No geometry, no textures — just distance math.
//
// The scene is an INFINITE procedural city along a winding road:
//   - the road centerline is an analytic curve x = roadX(z) (see game/road.ts,
//     which MUST stay in sync with the RD_* constants + roadX/roadDX below);
//   - the ground is the exact y=0 plane; the road + lane lines are a MATERIAL
//     painted onto it, so map() stays a valid distance bound;
//   - buildings are domain-repeated boxes tiled in "road space", hashed per cell
//     for footprint / height / windows / neon so the skyline is endless but
//     deterministic (hash contract shared with game/hash.ts).
// ============================================================================

in vec2 vUv;
out vec4 fragColor;

uniform vec2  uResolution;   // drawing-buffer size in pixels
uniform float uTime;         // seconds since start

// Camera ray basis supplied by camera.ts (see game/camera.ts).
uniform vec3 uCamPos;
uniform vec3 uCamRight;
uniform vec3 uCamUp;
uniform vec3 uCamForward;

// --- Marcher constants -------------------------------------------------------
// A long view straight down a road canyon needs many small steps, so MAX_STEPS
// is high and MAX_DIST reaches deep; fog (below) hides the far clip so raising
// these further only costs fps, never pops. renderScale in renderer.ts is the
// lever to pull first if fps drops on weaker GPUs.
const int   MAX_STEPS = 128;
const float MAX_DIST  = 180.0;
const float FOV_SCALE = 1.2;   // larger = wider field of view

// --- Material ids ------------------------------------------------------------
const float MAT_GROUND   = 0.0;  // ground plane: asphalt road OR dark terrain
const float MAT_BUILDING = 1.0;  // domain-repeated city blocks

// ============================================================================
// Road centerline — IDENTICAL to game/road.ts (see the sync contract there).
// Amplitudes + frequencies (2*pi / wavelength for 200 / 95 / 55 unit waves).
// ============================================================================
const float RD_A1 = 6.0,        RD_A2 = 3.0,        RD_A3 = 1.2;
const float RD_F1 = 0.03141593, RD_F2 = 0.06613879, RD_F3 = 0.11424174;
const float RD_P2 = 1.7,        RD_P3 = 4.2;

// NOTE: only roadX is needed for rendering; game/road.ts additionally defines
// roadDX/roadDir (the tangent) for CPU-side path/physics use. All share the RD_*
// constants above, so the rendered and driven roads stay identical.
float roadX(float z) {
    return RD_A1 * sin(z * RD_F1)
         + RD_A2 * sin(z * RD_F2 + RD_P2)
         + RD_A3 * sin(z * RD_F3 + RD_P3);
}

// --- Road cross-section (mirrored in game/road.ts) --------------------------
const float ROAD_HALF_WIDTH = 4.5;
const float LANE_W          = 2.25; // ROAD_HALF_WIDTH / 2 -> 2 lanes per side
const float SHOULDER        = 1.5;

// --- City block layout -------------------------------------------------------
// SETBACK = ROAD_HALF_WIDTH + SHOULDER + 2.0 gap: the x offset from the road
// centerline to the first row of buildings. Blocks tile outward from there.
const float SETBACK     = 8.0;
const float BLOCK_WIDTH = 13.0;
const float BLOCK_DEPTH = 14.0;
const float MARGIN      = 1.5;  // min empty gap from a building face to its cell wall
const int   NROWS       = 2;    // depth layers of buildings per side (skyline tiers)

// ============================================================================
// Integer hashing — IDENTICAL to game/hash.ts (determinism contract). GLSL uint
// arithmetic wraps mod 2^32 exactly like JS Math.imul + `>>> 0`, and `>> Nu` is
// a logical shift like JS `>>>`, so both platforms produce the same 32-bit words
// for the same cell — the CPU can later place obstacles the GPU renders.
// ============================================================================
uint uhash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

uint hashCell(int cx, int cy, int cz) {
    uint h = uhash(uint(cx) * 0x9e3779b9u);
    h = uhash(h ^ (uint(cy) * 0x85ebca6bu));
    h = uhash(h ^ (uint(cz) * 0xc2b2ae35u));
    return h;
}

// Extract byte `shift..shift+8` of a hash word as a float in [0,1].
float hByte(uint h, int shift) {
    return float((h >> uint(shift)) & 255u) / 255.0;
}

// ============================================================================
// SDF primitives. Each returns the signed distance from p to the surface:
// negative inside, zero on the surface, positive outside.
// ============================================================================

float sdPlaneY(vec3 p) {
    // Ground plane at y = 0; distance is simply the height. Exact everywhere.
    return p.y;
}

float sdBox(vec3 p, vec3 halfExtents) {
    vec3 q = abs(p) - halfExtents;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// ============================================================================
// Building cells. Each (side, row, cellZ) hashes deterministically to a footprint
// and height. The building is CENTERED in its cell with at least MARGIN of empty
// space on every side; this guarantees a building never crosses into a neighbour
// cell, so for any point the nearest building is always in the current cell or an
// immediate neighbour — exactly the set map() evaluates. That is what keeps a
// domain-repeated SDF free of "holes" where a closer, un-evaluated cell would
// have been the true nearest surface.
// ============================================================================
struct Building {
    vec3  center;   // world-ish position in road space (x = p.x - roadX(p.z))
    vec3  halfExt;  // half extents; halfExt.y = height/2, center.y = height/2
    uint  seed;     // per-building hash driving materials
    bool  present;  // some cells are empty for skyline variety
};

Building getBuilding(int side, int row, int cz) {
    Building b;
    uint seed = hashCell(side, row, cz);
    b.seed = seed;

    // ~76% of cells are built; the rest are gaps that layer the skyline.
    b.present = (seed & 255u) > 60u;

    float cx = float(side) * (SETBACK + (float(row) + 0.5) * BLOCK_WIDTH);
    float cz2 = (float(cz) + 0.5) * BLOCK_DEPTH;

    // Footprint half extents, kept <= half the cell minus MARGIN (see note above).
    float hx = mix(2.5, BLOCK_WIDTH * 0.5 - MARGIN, hByte(seed, 3));
    float hz = mix(2.5, BLOCK_DEPTH * 0.5 - MARGIN, hByte(seed, 11));

    // Front row is mid-rise; deeper rows tower so the skyline reads in tiers.
    float rH = hByte(seed, 19);
    float height = (row == 0) ? mix(6.0, 14.0, rH) : mix(11.0, 34.0, rH);

    b.center  = vec3(cx, height * 0.5, cz2);
    b.halfExt = vec3(hx, height * 0.5, hz);
    return b;
}

// ============================================================================
// Scene description. Returns vec2(distance, materialId).
//
// WARPED-SPACE CAVEAT (interview talking point): buildings live in "road space"
// q = (p.x - roadX(p.z), p.y, p.z). Subtracting roadX(p.z) shears x by a function
// of z, so a box distance measured in q is NOT a true Euclidean distance in world
// space — the field is compressed by |grad(q.x)| = sqrt(1 + roadX'(z)^2). With our
// gentle road, |roadX'| <= ~0.52, so that factor peaks around 1.13. Multiplying
// the building distance by 0.8 (< 1/1.13) restores a valid Lipschitz lower bound:
// the marcher then always UNDERshoots and can never tunnel through a wall. The
// ground plane is unwarped and stays exact, so we shrink only the building term.
// ============================================================================
vec2 map(vec3 p) {
    // Ground plane (exact). Road is a material on top of it, decided in shade().
    vec2 scene = vec2(sdPlaneY(p), MAT_GROUND);

    // Into road space and find the cell we are longitudinally inside.
    vec3 q = vec3(p.x - roadX(p.z), p.y, p.z);
    int baseCz = int(floor(q.z / BLOCK_DEPTH));

    // Evaluate both sides, both rows, and the current z-cell plus its two
    // neighbours: the full local neighbourhood the margin guarantees is enough.
    // Worst case = 2 sides * NROWS rows * 3 z-cells = 12 box evals per map() call.
    float best = 1e9;
    for (int si = 0; si < 2; si++) {
        int side = (si == 0) ? -1 : 1;
        for (int row = 0; row < NROWS; row++) {
            for (int dz = -1; dz <= 1; dz++) {
                Building b = getBuilding(side, row, baseCz + dz);
                if (b.present) {
                    best = min(best, sdBox(q - b.center, b.halfExt));
                }
            }
        }
    }
    best *= 0.8; // warped-space safety factor (see caveat above)

    if (best < scene.x) scene = vec2(best, MAT_BUILDING);
    return scene;
}

// ============================================================================
// Normals via the tetrahedron offset trick: 4 map() calls instead of the 6 a
// central-difference gradient needs — a 33% saving on the hot path.
// ============================================================================
vec3 calcNormal(vec3 p) {
    const vec2 e = vec2(1.0, -1.0) * 0.0006;
    return normalize(
        e.xyy * map(p + e.xyy).x +
        e.yyx * map(p + e.yyx).x +
        e.yxy * map(p + e.yxy).x +
        e.xxx * map(p + e.xxx).x
    );
}

// ============================================================================
// Sphere tracing: step forward by the SDF value (always a safe distance) until
// we converge onto a surface or exhaust the budget.
// ============================================================================
vec2 raymarch(vec3 ro, vec3 rd) {
    float t = 0.0;
    float mat = -1.0;
    for (int i = 0; i < MAX_STEPS; i++) {
        vec3 p = ro + rd * t;
        vec2 hit = map(p);
        // Epsilon grows with distance: far surfaces need less precision and it
        // keeps the step count bounded.
        if (hit.x < 0.001 * t) {
            mat = hit.y;
            break;
        }
        t += hit.x;
        if (t > MAX_DIST) break;
    }
    return vec2(t, mat);
}

// ============================================================================
// Soft shadows: march toward the light tracking the closest approach to any
// surface. Budget trimmed (28 steps, 30-unit reach) since the city fills the
// field and full-range shadow marches would dominate the frame.
// ============================================================================
float softShadow(vec3 ro, vec3 rd, float k) {
    float res = 1.0;
    float t = 0.06;
    for (int i = 0; i < 28; i++) {
        float h = map(ro + rd * t).x;
        if (h < 0.001) return 0.0;
        res = min(res, k * h / t);
        t += clamp(h, 0.03, 0.8);
        if (t > 30.0) break;
    }
    return clamp(res, 0.0, 1.0);
}

// Cheap ambient occlusion: sample the field a few steps along the normal; where
// it falls behind the distance travelled, the point sits in a crevice.
float calcAO(vec3 p, vec3 n) {
    float occ = 0.0;
    float scale = 1.0;
    for (int i = 0; i < 5; i++) {
        float h = 0.02 + 0.18 * float(i);
        float d = map(p + n * h).x;
        occ += (h - d) * scale;
        scale *= 0.7;
    }
    return clamp(1.0 - 1.4 * occ, 0.0, 1.0);
}

// ============================================================================
// Palette + sky. Synthwave night: near-black sky, magenta horizon glow, a small
// deterministic starfield, and a bright synthwave window palette.
// ============================================================================

// Five emissive window / neon colours; index chosen from a hash.
vec3 neonPalette(uint h) {
    uint i = h % 5u;
    if (i == 0u) return vec3(0.10, 1.00, 1.00); // cyan
    if (i == 1u) return vec3(1.00, 0.15, 0.70); // magenta
    if (i == 2u) return vec3(1.00, 0.75, 0.15); // amber/yellow
    if (i == 3u) return vec3(1.00, 0.40, 0.08); // orange
    return vec3(0.55, 0.75, 1.00);              // blue-white
}

// Sparse hashed stars for upward rays. The sky is diced into cells; a few cells
// hold a star at a hashed sub-position, drawn as a small round dot (not a full
// cell) so the field reads as points rather than blocks.
vec3 starField(vec3 rd) {
    if (rd.y < 0.04) return vec3(0.0);
    vec2 sp   = (rd.xz / (rd.y + 0.35)) * 42.0;
    vec2 cell = floor(sp);
    uint hs = hashCell(int(cell.x), int(cell.y), 4919);
    if (hByte(hs, 0) < 0.985) return vec3(0.0);         // ~1.5% of cells hold a star
    vec2  starPos = vec2(hByte(hs, 8), hByte(hs, 16));  // jittered within the cell
    float dot = smoothstep(0.14, 0.0, length(fract(sp) - starPos));
    float twinkle = 0.7 + 0.3 * sin(uTime * 2.0 + float(hs & 63u));
    return vec3(dot) * twinkle * 0.7 * smoothstep(0.0, 0.25, rd.y);
}

// Sky gradient for rays that miss everything.
vec3 skyColor(vec3 rd) {
    float h = clamp(rd.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 horizon = vec3(0.55, 0.06, 0.32);   // magenta/pink glow
    vec3 zenith  = vec3(0.02, 0.01, 0.05);   // near-black
    vec3 col = mix(horizon, zenith, pow(h, 0.55));
    // A soft ground-hugging band brightens the horizon.
    col += horizon * 0.4 * pow(1.0 - abs(rd.y), 6.0);
    col += starField(rd);
    return col;
}

// ============================================================================
// Surface description handed to the lighting model: base colour, how metallic
// (drives specular tightness + environment reflection), and emissive add.
// ============================================================================
struct Surface {
    vec3  albedo;
    float metal;
    vec3  emissive;
};

// --- Road / ground surface ---------------------------------------------------
// Decides asphalt vs. curb vs. terrain from lateral distance to the centerline,
// and paints emissive lane lines. The asphalt is given a wet metallic sheen so
// the sky and neon smear across it at grazing angles.
Surface roadSurface(vec3 p) {
    Surface s;
    float d  = p.x - roadX(p.z);
    float ad = abs(d);

    if (ad < ROAD_HALF_WIDTH) {
        s.albedo   = vec3(0.018, 0.018, 0.026);
        s.metal    = 0.35;                  // wet-look reflectivity
        s.emissive = vec3(0.0);

        // Glowing lane markings, all cyan to match the reference:
        float lines = 0.0;
        // Solid edge lines just inside both road edges.
        lines += smoothstep(0.12, 0.0, abs(ad - (ROAD_HALF_WIDTH - 0.3)));
        // Double solid line down the centre (two thin lines at +/- 0.18).
        lines += smoothstep(0.07, 0.0, abs(ad - 0.18));
        // Dashed separators between the two lanes on each side.
        float dash = step(0.55, fract(p.z * 0.18));
        lines += smoothstep(0.09, 0.0, abs(ad - LANE_W)) * dash;

        s.emissive = vec3(0.15, 1.0, 1.1) * clamp(lines, 0.0, 1.0) * 1.3;
    } else if (ad < ROAD_HALF_WIDTH + SHOULDER) {
        // Curb / shoulder, with a faint magenta edge strip against the asphalt.
        s.albedo   = vec3(0.04, 0.035, 0.05);
        s.metal    = 0.1;
        s.emissive = vec3(0.9, 0.12, 0.55)
                   * smoothstep(0.16, 0.0, abs(ad - ROAD_HALF_WIDTH)) * 0.5;
    } else {
        // Dark terrain beyond the shoulder.
        s.albedo   = vec3(0.01, 0.01, 0.016);
        s.metal    = 0.0;
        s.emissive = vec3(0.0);
    }
    return s;
}

// --- Building surface --------------------------------------------------------
// Recovers which building the hit belongs to (margins guarantee the cell lookup
// is unambiguous), then paints a procedural window grid + optional neon trim.
Surface buildingSurface(vec3 p, vec3 n) {
    Surface s;
    s.albedo   = vec3(0.015, 0.015, 0.025); // very dark body, keeps metallic sheen
    s.metal    = 0.7;
    s.emissive = vec3(0.0);

    // Back into road space and identify the owning cell.
    vec3 q = vec3(p.x - roadX(p.z), p.y, p.z);
    int cz   = int(floor(q.z / BLOCK_DEPTH));
    int side = (q.x < 0.0) ? -1 : 1;
    int row  = int(floor((abs(q.x) - SETBACK) / BLOCK_WIDTH));
    row = clamp(row, 0, NROWS - 1);

    Building b = getBuilding(side, row, cz);
    vec3 lp = q - b.center;               // local coords, within +/- halfExt
    uint seed = b.seed;

    // Per-building window metrics.
    float winW   = mix(2.0, 3.2, hByte(seed, 5));   // window spacing across a face
    float floorH = mix(1.9, 2.6, hByte(seed, 13));  // floor-to-floor height
    vec3  litCol = neonPalette(seed);

    vec3 an = abs(n);
    if (an.y > an.x && an.y > an.z) {
        // Roof: leave it as the dark metallic body (no windows).
    } else {
        // Vertical face: pick the horizontal axis along the wall and a face id.
        float u;
        int faceId;
        if (an.x > an.z) { u = lp.z; faceId = (n.x > 0.0) ? 0 : 1; }
        else             { u = lp.x; faceId = (n.z > 0.0) ? 2 : 3; }

        // Window grid: horizontal along u, vertical measured from the base.
        vec2 g  = vec2(u / winW, (lp.y + b.halfExt.y) / floorH);
        vec2 gi = floor(g);
        vec2 f  = fract(g);
        // A window occupies the inner part of each grid cell (framed border).
        bool inWindow = f.x > 0.16 && f.x < 0.84 && f.y > 0.22 && f.y < 0.82;

        if (inWindow) {
            uint ws = uhash(seed ^ hashCell(int(gi.x), int(gi.y), faceId));
            bool lit = hByte(ws, 0) < 0.5;   // ~50% of windows are lit
            if (lit) {
                // Slight flicker so the city feels alive without strobing.
                float flick = 0.85 + 0.15 * sin(uTime * 3.0 + float(ws & 31u));
                s.emissive = litCol * (1.4 * flick);
                s.albedo   = litCol * 0.05;
            } else {
                s.albedo = vec3(0.02, 0.02, 0.03); // dark unlit glass
            }
        }
        // else: mullion / wall between windows keeps the dark body albedo.

        // Optional neon roofline trim on a hashed subset of buildings.
        if (((seed >> 24) & 3u) == 0u && lp.y > b.halfExt.y - 0.4) {
            s.emissive += litCol * 2.0;
        }
    }
    return s;
}

// ============================================================================
// Lighting model. Blinn-Phong base + metallic environment reflection (what makes
// surfaces read as wet asphalt / dark metal) + emissive add for neon.
// ============================================================================
vec3 shade(vec3 p, vec3 rd, float mat) {
    vec3 n = calcNormal(p);

    // if/else rather than a ?: so no driver balks at a struct-typed ternary.
    Surface sf;
    if (mat == MAT_BUILDING) sf = buildingSurface(p, n);
    else                     sf = roadSurface(p);

    // Key directional light, cool tone to sit against the warm sky.
    vec3 lightDir = normalize(vec3(-0.5, 0.8, -0.25));
    vec3 lightCol = vec3(0.5, 0.65, 1.0);

    float ambient = 0.16;
    float diff    = max(dot(n, lightDir), 0.0);
    float shadow  = softShadow(p + n * 0.03, lightDir, 12.0);
    diff *= shadow;

    vec3  halfVec = normalize(lightDir - rd);
    float spec = pow(max(dot(n, halfVec), 0.0), mix(32.0, 140.0, sf.metal)) * shadow;

    float ao = calcAO(p, n);

    vec3 color = sf.albedo * (ambient * ao);
    color += sf.albedo * lightCol * diff;
    color += lightCol * spec * mix(0.4, 2.0, sf.metal);

    // Metallic environment reflection, Schlick-fresnel weighted so reflectivity
    // climbs at grazing angles — this is what smears the sky/neon along the wet
    // road and puts a sheen on the dark building faces.
    float fresnel = pow(1.0 - max(dot(n, -rd), 0.0), 5.0);
    vec3  reflected = skyColor(reflect(rd, n));
    color += reflected * mix(0.03, 0.6, sf.metal) * (0.25 + 0.75 * fresnel) * ao;

    color += sf.emissive;
    return color;
}

// ACES-ish filmic tone map (Narkowicz approximation): compresses HDR into
// [0,1] with a filmic shoulder so neon highlights don't clip to flat white.
vec3 toneMapACES(vec3 x) {
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    // Aspect-correct pixel coordinates in [-1,1], y up.
    vec2 uv = (vUv * 2.0 - 1.0);
    uv.x *= uResolution.x / uResolution.y;

    // Build the primary ray from the camera basis.
    vec3 ro = uCamPos;
    vec3 rd = normalize(uCamForward + FOV_SCALE * (uv.x * uCamRight + uv.y * uCamUp));

    vec2 hit = raymarch(ro, rd);
    float t = hit.x;
    float mat = hit.y;

    vec3 color;
    if (mat < 0.0) {
        color = skyColor(rd);
    } else {
        vec3 p = ro + rd * t;
        color = shade(p, rd, mat);
        // Distance fog: dissolve the far city into the horizon glow. Tuned so the
        // scene is ~90% faded by MAX_DIST (exp(-0.00007 * 180^2) ~= 0.1), hiding
        // both the far clip and any tiling that would otherwise reveal itself.
        float fog = 1.0 - exp(-0.00007 * t * t);
        color = mix(color, skyColor(rd), fog);
    }

    // Tone map then gamma-correct (linear -> sRGB) for display.
    color = toneMapACES(color);
    color = pow(color, vec3(1.0 / 2.2));

    fragColor = vec4(color, 1.0);
}
