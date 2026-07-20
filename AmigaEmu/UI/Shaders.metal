// Metal shaders for the Amiga framebuffer display.
//
// vAmiga renders into a fixed 912×313 RGBA8 CPU texture; the visible
// picture is a sub-rectangle (the rest is HBLANK/VBLANK/border). We upload
// the whole texture and bilinear-sample only the crop window — same idea
// as the apple2ts/IIGS pipeline (clean GPU upscale, no upscaler chain).

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut amiga_vertex(uint vid [[vertex_id]]) {
    constexpr float2 verts[4] = {
        float2(-1.0,  1.0), float2( 1.0,  1.0),
        float2(-1.0, -1.0), float2( 1.0, -1.0)
    };
    constexpr float2 uvs[4] = {
        float2(0.0, 0.0), float2(1.0, 0.0),
        float2(0.0, 1.0), float2(1.0, 1.0)
    };
    VertexOut out;
    out.position = float4(verts[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

struct DisplayParams {
    float4 crop;   // (x0, y0, x1, y1) in source UV — the visible window
};

fragment float4 amiga_fragment_display(VertexOut in [[stage_in]],
                                       texture2d<float> src [[texture(0)]],
                                       constant DisplayParams &p [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = float2(mix(p.crop.x, p.crop.z, in.uv.x),
                       mix(p.crop.y, p.crop.w, in.uv.y));
    return float4(src.sample(smp, uv).rgb, 1.0);
}
