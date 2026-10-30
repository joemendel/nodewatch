# NodeWatch

A menu bar app that shows which dev servers are running on this Mac, who started them, and lets you open or stop them.

Built because AI agents often start a server and never mention it.

## What it shows

For every node, bun or deno process listening on a TCP port (Python optional):

- **Port and project folder**: the folder is the process's working directory.
- **Who started it**: found by walking the parent processes (Claude Code, Codex, Cursor, a terminal, or a launchd service). If the launcher has exited, the server's environment is checked for agent markers such as `CLAUDECODE=1`. `ps` returns the whole environment, which in agent sessions includes tokens; NodeWatch matches only the marker names, never logs or shows the rest, and reads each server's environment once, not on every poll. Markers in a process's arguments are ignored, so a process can't fake its launcher that way.
- **Network exposure**: an orange warning when a server is bound to anything other than loopback (`127.0.0.1` / `::1`): all interfaces, a LAN address, or a VPN address. Those are reachable from other machines. Open uses the bound address when a server doesn't answer on localhost.
- **Uptime**, the command that was run, and the PID.

Actions: **Open** (in your browser), **Show Folder**, **Stop** (click twice to confirm; sends SIGTERM, then offers **Force Stop** if the server is still running 2 seconds later). Before any signal, NodeWatch checks the process's start time still matches, so a PID that macOS has reused for a different process is never signalled.

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
