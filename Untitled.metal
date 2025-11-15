//
//  VertexOutput.swift
//  snester
//
//  Created by kevin on 2025-11-15.
//


#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOutput vertex_main(const device float4 *vertices [[buffer(0)]],
                                uint vertexID [[vertex_id]]) {
    VertexOutput out;
    float4 data = vertices[vertexID];
    out.position = float4(data.xy, 0.0, 1.0);
    out.texCoord = data.zw;
    return out;
}

fragment float4 fragment_main(VertexOutput in [[stage_in]],
                              texture2d<float> screenTexture [[texture(0)]]) {
    constexpr sampler screenSampler (address::clamp_to_edge, filter::nearest);
    return screenTexture.sample(screenSampler, in.texCoord);
}
