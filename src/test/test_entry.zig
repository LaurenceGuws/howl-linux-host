test {
    @import("std").testing.refAllDecls(@import("cli_args"));
    @import("std").testing.refAllDecls(@import("config_env"));
    @import("std").testing.refAllDecls(@import("process_accounting"));
    @import("std").testing.refAllDecls(@import("retained_render"));
    @import("std").testing.refAllDecls(@import("tab_bar"));
}
