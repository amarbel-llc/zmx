# zmx fork command — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement
> this plan task-by-task.

**Goal:** Add a `fork` command that creates a new detached session with the same
startup command and working directory as the current session.

**Architecture:** Pure client-side command. Reads `$ZMX_SESSION`, probes the
source session for cmd+cwd via existing IPC, `chdir`s to source cwd, creates a
`Daemon` struct, calls `ensureSession()` to spawn the new daemon, then exits
without attaching. No IPC protocol changes.

**Tech Stack:** Zig 0.15.2, existing zmx IPC and session machinery.

---

## Design

### Synopsis

```
zmx fork [f] [<new-session-name>]
```

### Behavior

1. Must be run inside an existing zmx session (reads `$ZMX_SESSION`)
2. Probes the source session to retrieve its startup command and cwd
3. Creates a new detached session with the same command+cwd
4. Does NOT attach to the new session

### Name resolution

- If `<new-session-name>` is provided, use it verbatim. Error if already exists.
- If omitted, derive from source: `<source>-1`, `<source>-2`, etc. Scan existing
  socket files to find next available number.

### Error cases

| Condition                     | Behavior                               |
| ----------------------------- | -------------------------------------- |
| `$ZMX_SESSION` not set        | Error: "are you inside a zmx session?" |
| Source session unresponsive    | Error + stale socket cleanup           |
| Target name already exists     | Error: "session already exists"        |
| Source has no explicit command | Launch default shell in source's cwd   |

### Key detail: command serialization

The IPC `Info` struct stores the command as a space-joined string
(`handleInfo` at `main.zig:270-286`). When forking, we split this string on
spaces to reconstruct the argv array. This is lossy for args containing spaces,
but matches how `zmx list` already displays commands.

### Key detail: working directory

`spawnPty` does not explicitly `chdir` — the PTY child inherits the daemon's cwd.
The fork function must `chdir` to the source session's cwd before calling
`ensureSession()` so the new daemon (and its PTY child) start in the right
directory.

---

### Task 1: Add `fork` function

**Files:**
- Modify: `src/main.zig` (add function after `detachSession`, ~line 700)

**Step 1: Write the `fork` function**

Add after the `detachSession` function (after line ~700):

```zig
fn fork(cfg: *Cfg, target_name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Must be inside a zmx session
    const source_name = std.process.getEnvVarOwned(alloc, "ZMX_SESSION") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.log.err("ZMX_SESSION env var not found: are you inside a zmx session?", .{});
            return;
        },
        else => return err,
    };
    defer alloc.free(source_name);

    // Probe source session for cmd + cwd
    const source_socket_path = try getSocketPath(alloc, cfg.socket_dir, source_name);
    defer alloc.free(source_socket_path);

    const source_encoded = try encodeSessionName(alloc, source_name);
    defer alloc.free(source_encoded);

    const result = probeSession(alloc, source_socket_path) catch |err| {
        std.log.err("source session unresponsive: {s}", .{@errorName(err)});
        var dir = std.fs.openDirAbsolute(cfg.socket_dir, .{}) catch return;
        defer dir.close();
        cleanupStaleSocket(dir, source_encoded);
        return;
    };
    posix.close(result.fd);

    // Check target doesn't already exist
    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const target_encoded = try encodeSessionName(alloc, target_name);
    defer alloc.free(target_encoded);

    const exists = sessionExists(dir, target_encoded) catch false;
    if (exists) {
        std.log.err("session already exists: {s}", .{target_name});
        return;
    }

    // Extract command args from space-joined string
    const cmd_str = result.info.cmd[0..result.info.cmd_len];
    var command_args: std.ArrayList([]const u8) = .empty;
    defer command_args.deinit(alloc);

    if (cmd_str.len > 0) {
        var iter = std.mem.splitScalar(u8, cmd_str, ' ');
        while (iter.next()) |arg| {
            if (arg.len > 0) {
                try command_args.append(alloc, arg);
            }
        }
    }

    var command: ?[][]const u8 = null;
    if (command_args.items.len > 0) {
        command = command_args.items;
    }

    // chdir to source cwd so new daemon inherits it
    const source_cwd = result.info.cwd[0..result.info.cwd_len];
    if (source_cwd.len > 0) {
        std.posix.chdir(source_cwd) catch |err| {
            std.log.warn("could not chdir to {s}: {s}", .{ source_cwd, @errorName(err) });
        };
    }

    // Spawn new session without attaching
    const c_alloc = std.heap.c_allocator;
    const clients = try std.ArrayList(*Client).initCapacity(c_alloc, 10);

    var daemon = Daemon{
        .running = true,
        .cfg = cfg,
        .alloc = c_alloc,
        .clients = clients,
        .session_name = target_name,
        .socket_path = undefined,
        .pid = undefined,
        .command = command,
        .cwd = source_cwd,
    };
    daemon.socket_path = try getSocketPath(c_alloc, cfg.socket_dir, target_name);

    std.log.info("forking session={s} from={s}", .{ target_name, source_name });
    const ensure_result = try ensureSession(&daemon);
    if (ensure_result.is_daemon) return;
}
```

**Step 2: Build and verify it compiles**

Run: `just build` (or `nix build`)
Expected: Compiles (function is unused, but should parse)

**Step 3: Commit**

```
feat: add fork function for creating sessions from existing ones
```

---

### Task 2: Add auto-name generation

**Files:**
- Modify: `src/main.zig` (add `nextForkName` helper, modify `fork` dispatch)

**Step 1: Write the `nextForkName` helper**

Add near the `fork` function:

```zig
fn nextForkName(alloc: std.mem.Allocator, dir: std.fs.Dir, base_name: []const u8) ![]const u8 {
    var i: u32 = 1;
    while (i < 1000) : (i += 1) {
        const candidate = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ base_name, i });
        const encoded = encodeSessionName(alloc, candidate) catch {
            alloc.free(candidate);
            continue;
        };
        defer alloc.free(encoded);

        const exists = sessionExists(dir, encoded) catch false;
        if (!exists) return candidate;
        alloc.free(candidate);
    }
    return error.TooManySessions;
}
```

**Step 2: Build and verify**

Run: `just build`
Expected: Compiles

**Step 3: Commit**

```
feat: add nextForkName helper for auto-generating fork session names
```

---

### Task 3: Add command dispatch and wiring

**Files:**
- Modify: `src/main.zig:366-368` (add dispatch branch)

**Step 1: Add the dispatch entry**

In `main()`, add before the `detach-all` branch (around line 366):

```zig
    } else if (std.mem.eql(u8, cmd, "fork") or std.mem.eql(u8, cmd, "f")) {
        const target_name: ?[]const u8 = args.next();
        return forkSession(&cfg, target_name);
    }
```

**Step 2: Write the `forkSession` wrapper**

This thin wrapper handles the optional name argument, calling `nextForkName` when
no name is given:

```zig
fn forkSession(cfg: *Cfg, explicit_name: ?[]const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    if (explicit_name) |name| {
        return fork(cfg, name);
    }

    // Auto-generate name from $ZMX_SESSION
    const source_name = std.process.getEnvVarOwned(alloc, "ZMX_SESSION") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.log.err("ZMX_SESSION env var not found: are you inside a zmx session?", .{});
            return;
        },
        else => return err,
    };
    defer alloc.free(source_name);

    var dir = try std.fs.openDirAbsolute(cfg.socket_dir, .{});
    defer dir.close();

    const auto_name = try nextForkName(alloc, dir, source_name);
    defer alloc.free(auto_name);

    return fork(cfg, auto_name);
}
```

**Step 3: Build and verify**

Run: `just build`
Expected: Compiles and links

**Step 4: Commit**

```
feat: wire fork command into CLI dispatch with auto-naming
```

---

### Task 4: Update help text

**Files:**
- Modify: `src/main.zig:482-500` (help function)

**Step 1: Add fork to help text**

Add after the `[da] detach-all` line:

```
\\  [f]ork [<name>]               Fork current session (new detached session with same command)
```

**Step 2: Build and verify**

Run: `just build`

**Step 3: Commit**

```
docs: add fork command to help text
```

---

### Task 5: Update shell completions

**Files:**
- Modify: `src/completions.zig`

**Step 1: Update bash completions**

In `bash_completions` (line 32), add `fork` to the commands list:

```
\\  local commands="attach run detach detach-all fork list completions kill history version help"
```

No session-name completion needed for fork (it creates new names, doesn't
complete existing ones).

**Step 2: Update zsh completions**

In `zsh_completions` (line 72-83), add to the commands array:

```
\\        'fork:Fork current session with same command'
```

**Step 3: Update fish completions**

In `fish_completions` (line 122), add `fork` to the subcommands set:

```
\\set -l subcommands attach run detach detach-all fork list completions kill history version help
```

Add the completion entry:

```
\\complete -c zmx -n $no_subcmd -a fork -d 'Fork current session with same command'
```

**Step 4: Build and verify**

Run: `just build`

**Step 5: Commit**

```
feat: add fork to shell completions (bash, zsh, fish)
```

---

### Task 6: Manual test

**Step 1: Start a session with a command**

```
zmx attach test-fork vim
```

**Step 2: From inside the session, fork with explicit name**

```
zmx fork test-fork-copy
```

**Step 3: Verify new session exists**

```
zmx list
```

Expected: Both `test-fork` and `test-fork-copy` visible, `test-fork-copy` shows
same command (`vim`) and same cwd.

**Step 4: Test auto-naming**

```
zmx fork
```

Expected: Creates `test-fork-1`.

**Step 5: Test error on duplicate name**

```
zmx fork test-fork-copy
```

Expected: Error message about session already existing.

**Step 6: Clean up**

```
zmx kill test-fork
zmx kill test-fork-copy
zmx kill test-fork-1
```

**Step 7: Commit (if any fixes were needed)**
