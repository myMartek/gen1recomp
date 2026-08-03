//  Draws LÖVE's virtual screen into the immersive drawables.
//
//  A fullscreen triangle rather than a quad: three vertices, no vertex buffer,
//  no index buffer. The extra area outside the viewport is clipped away and
//  costs nothing, and it avoids the diagonal seam two triangles can show.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct ScreenUniforms {
    // Scales the UVs so the source keeps its aspect ratio inside the target.
    // Values above 1 letterbox: the shader discards what falls outside.
    float2 uvScale;
};

vertex VertexOut gr_screen_vertex(uint vid [[vertex_id]])
{
    // (-1,-1) (3,-1) (-1,3) -- covers the viewport with one triangle.
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    const float2 uvs[3]       = { float2( 0.0,  1.0), float2(2.0,  1.0), float2( 0.0, -1.0) };

    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 gr_screen_fragment(VertexOut in [[stage_in]],
                                   texture2d<float> screen [[texture(0)]],
                                   constant ScreenUniforms &u [[buffer(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    // Centre the scaled UVs, then drop anything outside the source. Sampling
    // with clamp_to_edge instead would smear the border pixels across the
    // letterbox, which reads as a rendering bug rather than as empty space.
    float2 uv = (in.uv - 0.5) * u.uvScale + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return float4(0.0, 0.0, 0.0, 1.0);

    return float4(screen.sample(s, uv).rgb, 1.0);
}
