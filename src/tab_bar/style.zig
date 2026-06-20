const render_c = @import("howl_render_c");

pub const Colors = struct {
    foreground: render_c.HowlRenderRgba8,
    background: render_c.HowlRenderRgba8,
    font_style: u8,

    pub fn active() Colors {
        return .{
            .foreground = .{ .r = 240, .g = 245, .b = 252, .a = 255 },
            .background = .{ .r = 48, .g = 56, .b = 76, .a = 255 },
            .font_style = render_c.HOWL_RENDER_FONT_STYLE_BOLD,
        };
    }

    pub fn inactive() Colors {
        return .{
            .foreground = .{ .r = 194, .g = 204, .b = 219, .a = 255 },
            .background = .{ .r = 31, .g = 36, .b = 46, .a = 255 },
            .font_style = render_c.HOWL_RENDER_FONT_STYLE_REGULAR,
        };
    }

    pub fn separator() Colors {
        return .{
            .foreground = .{ .r = 92, .g = 105, .b = 130, .a = 255 },
            .background = .{ .r = 23, .g = 28, .b = 41, .a = 255 },
            .font_style = render_c.HOWL_RENDER_FONT_STYLE_REGULAR,
        };
    }
};
