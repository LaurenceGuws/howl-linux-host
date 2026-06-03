const render_surface_contract = @import("render_surface_contract");

test {
    @import("std").testing.refAllDecls(@import("cli_args"));
    @import("std").testing.refAllDecls(@import("config_env"));
    @import("std").testing.refAllDecls(@import("tab_bar"));
}

test "render surface contract owner validation" {
    try render_surface_contract.testContractOwnerValidation();
}
