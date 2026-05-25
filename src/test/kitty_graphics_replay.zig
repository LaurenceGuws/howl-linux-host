const std = @import("std");
const host = @import("host");

const TerminalConfig = host.Config.Terminal;
const Input = host.Input.Input;
const TerminalPanel = host.TerminalPanel.TerminalPanel;
const Window = host.Window;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const max_failure_turns: u32 = 12000;
const turn_sleep_ns: u64 = 1 * std.time.ns_per_ms;
const bash_path = "/bin/bash";
const replay_rel_path = "src/test/fixtures/kitty_graphics_app_icon_replay.sh";
const primary_font_rel_path = "assets/fonts/IosevkaTermNerdFont-Regular.ttf";

test "kitty graphics replay stays healthy through panel teardown" {
    try std.testing.expect(setenv("SDL_VIDEODRIVER", "dummy", 1) == 0);
    try std.testing.expect(setenv("TERM", "xterm-256color", 1) == 0);
    try std.testing.expect(Window.initVideo());
    defer Window.quit();

    var input: Input = undefined;
    input.init();
    input.window_state.initEventTypes();

    var conf = try makeTerminalConfig(std.testing.allocator);
    defer conf.deinit(std.testing.allocator);

    var panel: TerminalPanel = undefined;
    var panel_live = false;
    try panel.init(
        std.Io.Threaded.global_single_threaded.io(),
        &input,
        null,
        &conf,
        640,
        480,
        640,
        480,
    );
    panel_live = true;
    defer if (panel_live) panel.deinit();

    try std.testing.expect(panel.live);
    try std.testing.expect(panel.progress.thread != null);

    var exited_cleanly = false;
    var turn: u32 = 0;
    while (turn < max_failure_turns) : (turn += 1) {
        _ = panel.driveProgress(true, Window.c_win.SDL_GetTicksNS());
        if (panel.sessionOutcome() == .runtime_failed) return error.TestUnexpectedResult;
        if (panel.sessionOutcome() == .exited) {
            try expectReplayExited(&panel);
            exited_cleanly = true;
            break;
        }
        try std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), std.Io.Duration.fromNanoseconds(turn_sleep_ns), .awake);
    }

    try std.testing.expect(exited_cleanly);

    panel.deinit();
    panel_live = false;
    try std.testing.expect(!panel.live);
    try std.testing.expect(panel.progress.thread == null);
}

test "kitty graphics replay stays healthy through window presentation" {
    try std.testing.expect(setenv("SDL_VIDEODRIVER", try displayDriver(), 1) == 0);
    try std.testing.expect(setenv("TERM", "xterm-256color", 1) == 0);
    try std.testing.expect(Window.initVideo());
    defer Window.quit();

    var input: Input = undefined;
    input.init();
    input.window_state.initEventTypes();

    var conf = try makeTerminalConfig(std.testing.allocator);
    defer conf.deinit(std.testing.allocator);

    const title = try std.testing.allocator.dupeZ(u8, "Howl Replay Test");
    defer std.testing.allocator.free(title);

    var window = try Window.State.create(title, 640, 480);
    defer window.deinit();
    try std.testing.expect(window.present_state.gl_context != null);

    const px = window.contentPixelSize(0);
    const logical = window.contentLogicalSize(0);

    var panel: TerminalPanel = undefined;
    var panel_live = false;
    try panel.init(
        std.Io.Threaded.global_single_threaded.io(),
        &input,
        null,
        &conf,
        px.width,
        px.height,
        logical.width,
        logical.height,
    );
    panel_live = true;
    defer if (panel_live) panel.deinit();

    var exited_cleanly = false;
    var turn_count: u32 = 0;
    while (turn_count < max_failure_turns) : (turn_count += 1) {
        _ = panel.driveProgress(true, Window.c_win.SDL_GetTicksNS());
        const turn = panel.renderTurn();
        panel.noteRenderTurn(turn);
        window.setTitle(panel.titleSlice());

        if (shouldPresent(turn.step)) {
            const rect = window.contentRect(0);
            const overlay = panel.overlaySnapshot(rect);
            window.present(.{
                .term_texture_id = @intCast(panel.termTextureId()),
                .term_texture_rect = rect,
                .scrollbar = overlay.scrollbar,
                .tab_count = 1,
                .active_tab = 0,
                .tab_labels = &.{"replay"},
            });
            panel.finishPresent();
        }

        if (panel.sessionOutcome() == .runtime_failed) return error.TestUnexpectedResult;
        if (panel.sessionOutcome() == .exited) {
            try expectReplayExited(&panel);
            exited_cleanly = true;
            break;
        }
        try std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), std.Io.Duration.fromNanoseconds(turn_sleep_ns), .awake);
    }

    try std.testing.expect(exited_cleanly);
    try std.testing.expect(panel.termTextureId() != 0);
    try std.testing.expect(window.present_state.first_present_logged);

    panel.deinit();
    panel_live = false;
    try std.testing.expect(!panel.live);
    try std.testing.expect(panel.progress.thread == null);
}

fn makeTerminalConfig(allocator: std.mem.Allocator) !TerminalConfig {
    const replay_abs = try realPathAlloc(allocator, replay_rel_path);
    defer allocator.free(replay_abs);
    const primary_font_abs = try realPathAlloc(allocator, primary_font_rel_path);
    defer allocator.free(primary_font_abs);
    const command = try std.fmt.allocPrint(allocator, "bash {s}", .{replay_abs});
    errdefer allocator.free(command);

    const bindings = try allocator.alloc(Input.Bindings.Binding, 0);
    errdefer allocator.free(bindings);

    return .{
        .shell = try allocator.dupe(u8, bash_path),
        .start_path = null,
        .command = command,
        .font_size = 16,
        .fonts = .{
            .primary = try allocator.dupeZ(u8, primary_font_abs),
            .mono = &.{},
            .symbols = &.{},
            .emoji = &.{},
        },
        .cursor = .{ .style = .bar, .blink = true },
        .clipboard = .{ .osc_52 = .deny },
        .links = .{ .open = .disabled, .hover = .off, .underline = .straight },
        .mouse = .{ .bypass_mod = .{} },
        .bindings = .{ .bindings = bindings },
    };
}

fn realPathAlloc(allocator: std.mem.Allocator, rel_path: []const u8) ![:0]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().realPathFileAlloc(io, rel_path, allocator);
}

fn shouldPresent(step: anytype) bool {
    return switch (step) {
        .rendered, .blocked_present => true,
        .no_frame, .idle_prepare, .idle_submit, .failed => false,
    };
}

fn expectReplayExited(panel: *TerminalPanel) !void {
    const snapshot = panel.ptySnapshot();
    try std.testing.expectEqual(.exited, panel.sessionOutcome());
    try std.testing.expectEqual(.ready, panel.lifecycleState());
    try std.testing.expectEqual(.stopped, snapshot.status);
    try std.testing.expect(snapshot.terminal_reason == .child_exit or snapshot.terminal_reason == .transport_eof);
}

fn displayDriver() ![*:0]const u8 {
    if (std.c.getenv("WAYLAND_DISPLAY") != null) return "wayland";
    if (std.c.getenv("DISPLAY") != null) return "x11";
    return error.SkipZigTest;
}
