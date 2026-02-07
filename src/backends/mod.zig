/// Terminal backend module exports.
/// This module provides the default terminal backend selection.

const terminal = @import("../terminal.zig");

pub const ghostty = @import("ghostty.zig");

/// The default terminal implementation using ghostty-vt
pub const DefaultTerminal = terminal.Terminal(ghostty.GhosttyBackend);
