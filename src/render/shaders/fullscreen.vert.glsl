#version 300 es

// Fullscreen triangle generated purely from gl_VertexID — no vertex buffer.
//
// One oversized triangle instead of a two-triangle quad: it covers the whole
// viewport with 3 vertices instead of 6 and has no diagonal seam, so pixels are
// never shaded twice along the quad's shared edge. We emit clip-space positions
// (-1..3) that extend past the screen; the parts outside [-1,1] get clipped.

out vec2 vUv;

void main() {
    // ids 0,1,2 -> uv (0,0),(2,0),(0,2) -> clip (-1,-1),(3,-1),(-1,3)
    vec2 uv = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    vUv = uv;
    gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
}
