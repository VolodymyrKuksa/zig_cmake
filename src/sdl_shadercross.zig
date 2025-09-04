pub const sc = @cImport({
    @cInclude("SDL3_shadercross/SDL_shadercross.h");
});

test {
    const std = @import("std");
    const testing = std.testing;

    try testing.expect(sc.SDL_ShaderCross_Init());
    defer sc.SDL_ShaderCross_Quit();

    const hlsl_info: sc.SDL_ShaderCross_HLSL_Info = .{
        .source = hlsl_source,
        .entrypoint = "main",
        .shader_stage = sc.SDL_GPU_SHADERSTAGE_VERTEX,
        .name = "test.vs.hlsl",
    };

    var spirv_size: usize = 0;
    const maybe_spirv_bytes = sc.SDL_ShaderCross_CompileSPIRVFromHLSL(&hlsl_info, &spirv_size);
    if (maybe_spirv_bytes == null) {
        std.debug.print("err: {s}\n", .{sc.SDL_GetError()});
    }
    try testing.expect(maybe_spirv_bytes != null);
    const spirv_bytes = maybe_spirv_bytes.?;

    const spirv_info: sc.SDL_ShaderCross_SPIRV_Info = .{
        .bytecode = @ptrCast(@alignCast(spirv_bytes)),
        .bytecode_size = spirv_size,
        .entrypoint = "main",
        .shader_stage = sc.SDL_GPU_SHADERSTAGE_VERTEX,
        .props = sc.SDL_CreateProperties(),
    };

    const maybe_mls_bytes = sc.SDL_ShaderCross_TranspileMSLFromSPIRV(&spirv_info);
    if (maybe_spirv_bytes == null) {
        std.debug.print("err: {s}\n", .{sc.SDL_GetError()});
    }
    try testing.expect(maybe_mls_bytes != null);
    const msl_bytes_raw: [*c]u8 = @ptrCast(@alignCast(maybe_mls_bytes.?));
    const msl_bytes_len = std.mem.len(msl_bytes_raw);
    const msl_bytes = msl_bytes_raw[0..msl_bytes_len];

    try testing.expectEqualStrings(msl_expected, msl_bytes);
}

const hlsl_source: [:0]const u8 =
    \\struct Input
    \\{
    \\    float3 Position : TEXCOORD0;
    \\    float4 Color : TEXCOORD1;
    \\};
    \\
    \\struct Output
    \\{
    \\    float4 Color : TEXCOORD0;
    \\    float4 Position : SV_Position;
    \\};
    \\
    \\Output main(Input input)
    \\{
    \\    Output output;
    \\    output.Color = input.Color;
    \\    output.Position = float4(input.Position, 1.0f);
    \\    return output;
    \\}
    \\
;

const msl_expected: [:0]const u8 =
    \\#include <metal_stdlib>
    \\#include <simd/simd.h>
    \\
    \\using namespace metal;
    \\
    \\struct main0_out
    \\{
    \\    float4 out_var_TEXCOORD0 [[user(locn0)]];
    \\    float4 gl_Position [[position]];
    \\};
    \\
    \\struct main0_in
    \\{
    \\    float3 in_var_TEXCOORD0 [[attribute(0)]];
    \\    float4 in_var_TEXCOORD1 [[attribute(1)]];
    \\};
    \\
    \\vertex main0_out main0(main0_in in [[stage_in]])
    \\{
    \\    main0_out out = {};
    \\    out.out_var_TEXCOORD0 = in.in_var_TEXCOORD1;
    \\    out.gl_Position = float4(in.in_var_TEXCOORD0, 1.0);
    \\    return out;
    \\}
    \\
    \\
;
