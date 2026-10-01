//! Windows console modules for the ConPTY driver and the VT input probe in
//! `tests/e2e/fixtures/`.

pub const conpty = @import("core/terminal/conpty.zig");
pub const win32 = @import("core/shared/win32.zig");

test {
    _ = conpty;
}
