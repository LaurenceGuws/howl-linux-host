pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_opengl.h");
    @cInclude("howl_pty.h");
    @cInclude("howl_vt.h");
    @cInclude("howl_render.h");
});
