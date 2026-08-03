//  Draws LÖVE's virtual screen as a world-locked panel in the immersive space.
//
//  World-locked rather than head-locked on purpose: a panel that follows your
//  head proves nothing about tracking, whereas one that stays put while you
//  look around proves the device anchor, the per-view transforms and the
//  projection are all correct together. It is also the presentation the flat
//  game actually wants in VR -- a screen hanging in the room.

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct PanelUniforms {
    float4x4 modelViewProjection;
    // Half-extents of the panel in metres, so one quad serves any aspect.
    float2   halfSize;
};

vertex VertexOut gr_panel_vertex(uint vid [[vertex_id]],
                                 constant PanelUniforms &u [[buffer(0)]])
{
    // Two triangles as a strip: bottom-left, bottom-right, top-left, top-right.
    const float2 corners[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    // v is flipped against y: Metal textures have their origin at the top,
    // and the panel's +y is up in world space.
    const float2 uvs[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };

    float2 c = corners[vid] * u.halfSize;

    VertexOut out;
    out.position = u.modelViewProjection * float4(c.x, c.y, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 gr_panel_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> screen [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(screen.sample(s, in.uv).rgb, 1.0);
}
