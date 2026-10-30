# NodeWatch

A menu bar app that shows which dev servers are running on this Mac, who started them, and lets you open or stop them.

Built because AI agents often start a server and never mention it.

## What it shows

For every node, bun or deno process listening on a TCP port (Python optional):

- **Port and project folder**: the folder is the process's working directory.
- **Who started it**: found by walking the parent processes (Claude Code, Codex, Cursor, a terminal, or a launchd service). If the launcher has exited, the server's environment is checked for agent markers such as `CLAUDECODE=1`. Only those marker names are read: agent environments also hold tokens, and nothing else from them is kept or shown.
- **Network exposure**: an orange warning when a server listens on all interfaces (`*` / `0.0.0.0`) instead of `127.0.0.1`, which makes it reachable from other devices on your Wi-Fi.
- **Uptime**, the command that was run, and the PID.

Actions: **Open** (localhost in your browser), **Show Folder**, **Stop** (click twice to confirm; sends SIGTERM, then offers **Force Stop** if the server is still running 2 seconds later).

The menu bar shows a server icon with a count of running servers. Network exposure is flagged on each row inside the menu, not in the menu bar.

## Build

Needs Xcode (uses `swiftc` directly, no Xcode project).

```bash
./build.sh              # build, install to ~/Applications, relaunch
./build.sh --no-install # build only, into build/
```

The app is ad-hoc signed. Keep it in `~/Applications`, not in iCloud Drive: iCloud adds file attributes that break code signatures.

## Layout

- `Sources/Scanner.swift`: finds servers (`lsof`, `ps`, `launchctl`). No UI code.
- `Sources/ServerStore.swift`: state, 5-second polling, actions, notifications, launch at login.
- `Sources/MenuView.swift`: the menu bar window.
- `Sources/NodeWatchApp.swift`: app entry point.
