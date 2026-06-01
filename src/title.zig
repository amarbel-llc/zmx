const std = @import("std");

/// Streaming parser that tracks the most recent window title set via the
/// terminal's OSC 0 (icon + window title) or OSC 2 (window title) sequences.
///
/// zmx passes raw PTY output straight through to attached clients, so a title
/// emitted by the inner shell only reaches the real terminal while a client is
/// attached. On re-attach the daemon replays serialized screen state but never
/// the title, so the outer terminal keeps whatever the previous foreground
/// process last set (see issue #6). This tracker captures the latest title from
/// the PTY byte stream so the daemon can re-emit it on attach.
///
/// The parser is intentionally minimal: it only recognizes `ESC ] 0 ; <text>`
/// and `ESC ] 2 ; <text>` terminated by BEL (0x07) or ST (`ESC \`). Every other
/// escape/OSC sequence is skipped. State persists across `feed` calls so titles
/// split across PTY reads are handled. No heap allocation: titles longer than
/// `max_len` bytes are dropped rather than truncated.
pub const TitleTracker = struct {
    pub const max_len = 2048;

    pub const Title = struct {
        /// The OSC code the title was set with (0 or 2).
        code: u8,
        /// The title text (may be empty, meaning the title was cleared).
        text: []const u8,
    };

    const State = enum {
        /// Outside any escape sequence.
        ground,
        /// Saw ESC (0x1b).
        esc,
        /// Inside `ESC ]`, reading the numeric OSC code up to ';'.
        osc_code,
        /// Inside an OSC 0/2 sequence, collecting title bytes into `pending`.
        collect,
        /// Saw ESC while collecting; expecting '\' to complete an ST terminator.
        collect_esc,
        /// Inside an OSC we don't capture; skipping until the terminator.
        skip,
        /// Saw ESC while skipping; expecting '\' to complete an ST terminator.
        skip_esc,
    };

    state: State = .ground,
    /// OSC code accumulated in the `osc_code` state.
    code_acc: u16 = 0,
    /// Title bytes for the in-progress OSC 0/2 sequence.
    pending: [max_len]u8 = undefined,
    pending_len: usize = 0,
    /// Set when the in-progress title overflowed `pending`; the sequence is
    /// dropped on completion rather than committing a truncated title.
    pending_overflow: bool = false,
    /// OSC code (0 or 2) of the in-progress collected title.
    pending_code: u8 = 0,

    /// Most recently committed title.
    committed: [max_len]u8 = undefined,
    committed_len: usize = 0,
    committed_code: u8 = 0,
    has_title: bool = false,

    const bel = 0x07;
    const esc_byte = 0x1b;

    pub fn feed(self: *TitleTracker, bytes: []const u8) void {
        for (bytes) |byte| self.feedByte(byte);
    }

    fn feedByte(self: *TitleTracker, byte: u8) void {
        switch (self.state) {
            .ground => if (byte == esc_byte) {
                self.state = .esc;
            },
            .esc => self.afterEsc(byte),
            .osc_code => switch (byte) {
                '0'...'9' => {
                    // Saturate rather than overflow; any absurd code just
                    // ends up in the skip path below once ';' arrives.
                    self.code_acc = self.code_acc *| 10 +| (byte - '0');
                },
                ';' => if (self.code_acc == 0 or self.code_acc == 2) {
                    self.state = .collect;
                    self.pending_len = 0;
                    self.pending_overflow = false;
                    self.pending_code = @intCast(self.code_acc);
                } else {
                    self.state = .skip;
                },
                esc_byte => self.state = .skip_esc,
                bel => self.state = .ground,
                // Unexpected byte in the code field (e.g. another OSC
                // parameter): treat the rest as an OSC we don't capture.
                else => self.state = .skip,
            },
            .collect => switch (byte) {
                bel => self.commitPending(),
                esc_byte => self.state = .collect_esc,
                else => {
                    if (self.pending_len < max_len) {
                        self.pending[self.pending_len] = byte;
                        self.pending_len += 1;
                    } else {
                        self.pending_overflow = true;
                    }
                },
            },
            .collect_esc => switch (byte) {
                '\\' => self.commitPending(),
                // Not an ST: the ESC cancelled the OSC and begins a new escape
                // sequence. Drop the partial title and reinterpret this byte.
                else => self.afterEsc(byte),
            },
            .skip => switch (byte) {
                bel => self.state = .ground,
                esc_byte => self.state = .skip_esc,
                else => {},
            },
            .skip_esc => switch (byte) {
                '\\' => self.state = .ground,
                else => self.afterEsc(byte),
            },
        }
    }

    /// Handle the byte following an ESC. ESC begins an escape sequence; we only
    /// care about the OSC introducer `]`. Any other byte (including ESC, which
    /// just restarts the wait) means this is a sequence we don't capture.
    fn afterEsc(self: *TitleTracker, byte: u8) void {
        switch (byte) {
            ']' => {
                self.state = .osc_code;
                self.code_acc = 0;
            },
            esc_byte => self.state = .esc,
            else => self.state = .ground,
        }
    }

    fn commitPending(self: *TitleTracker) void {
        // Drop overflowed titles instead of committing a truncated one.
        if (!self.pending_overflow) {
            @memcpy(self.committed[0..self.pending_len], self.pending[0..self.pending_len]);
            self.committed_len = self.pending_len;
            self.committed_code = self.pending_code;
            self.has_title = true;
        }
        self.state = .ground;
    }

    /// Returns the most recently captured title, or null if none seen yet.
    pub fn current(self: *const TitleTracker) ?Title {
        if (!self.has_title) return null;
        return .{
            .code = self.committed_code,
            .text = self.committed[0..self.committed_len],
        };
    }
};

fn expectTitle(tracker: *const TitleTracker, code: u8, text: []const u8) !void {
    const t = tracker.current() orelse return error.NoTitle;
    try std.testing.expectEqual(code, t.code);
    try std.testing.expectEqualStrings(text, t.text);
}

test "captures OSC 2 window title terminated by BEL" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]2;hello world\x07");
    try expectTitle(&tracker, 2, "hello world");
}

test "captures OSC 0 title terminated by ST" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]0;myterm\x1b\\");
    try expectTitle(&tracker, 0, "myterm");
}

test "most recent title wins" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]2;first\x07");
    tracker.feed("\x1b]2;second\x07");
    try expectTitle(&tracker, 2, "second");
}

test "title split across feeds" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]2;ti");
    tracker.feed("tle\x07");
    try expectTitle(&tracker, 2, "title");
}

test "ST terminator split across feeds" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]2;x\x1b");
    tracker.feed("\\");
    try expectTitle(&tracker, 2, "x");
}

test "ignores non-title OSC sequences" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]7;file:///tmp\x07");
    try std.testing.expect(tracker.current() == null);
}

test "ignores OSC 1 icon name" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]1;iconname\x07");
    try std.testing.expect(tracker.current() == null);
}

test "title embedded in surrounding output" {
    var tracker: TitleTracker = .{};
    tracker.feed("some text\x1b]2;T\x07more text");
    try expectTitle(&tracker, 2, "T");
}

test "empty title clears the title" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]2;set\x07");
    tracker.feed("\x1b]2;\x07");
    try expectTitle(&tracker, 2, "");
}

test "non-title OSC after a title does not clobber it" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]2;keep\x07");
    tracker.feed("\x1b]7;file:///tmp\x07");
    try expectTitle(&tracker, 2, "keep");
}

test "overlong title is dropped rather than truncated" {
    var tracker: TitleTracker = .{};
    tracker.feed("\x1b]2;short\x07");
    tracker.feed("\x1b]2;");
    var i: usize = 0;
    while (i < TitleTracker.max_len + 100) : (i += 1) tracker.feed("x");
    tracker.feed("\x07");
    // The overlong title was discarded; the prior title is still current.
    try expectTitle(&tracker, 2, "short");
}

test "OSC 2 is not confused by a preceding CSI sequence" {
    var tracker: TitleTracker = .{};
    // SGR reset (CSI 0 m) then a title; the digits/semicolon in the CSI
    // must not be mistaken for an OSC code.
    tracker.feed("\x1b[0m\x1b]2;ok\x07");
    try expectTitle(&tracker, 2, "ok");
}

test "title after a skipped OSC whose ESC introduces the new sequence" {
    var tracker: TitleTracker = .{};
    // An ignored OSC followed immediately by ESC ] (no BEL/ST between them):
    // the ESC must be recognized as starting a fresh OSC, not swallowed.
    tracker.feed("\x1b]1;icon\x1b]2;real\x07");
    try expectTitle(&tracker, 2, "real");
}
