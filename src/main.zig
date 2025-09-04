const sc = @import("SDL_shadercross").sc;
const std = @import("std");

pub fn main() void {
    const success = sc.SDL_ShaderCross_Init();
    std.debug.assert(success);
    defer sc.SDL_ShaderCross_Quit();

    std.debug.print("Hello World!\n", .{});
}
