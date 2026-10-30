# Changelog

## 1.1.0 (2026-10-30)

### Added
- Optional **Local (WordPress) sites** section. Turn on *Include Local (WordPress) sites* to see each running Local site as one row (name, `.local` domain, PHP version, uptime) with Open, Show Folder and Stop in Local, plus Local's shared router and Mailpit. Both are flagged when other devices on your network can reach them.

### Security
- The Local scan only looks at your own processes and only lists sites that Local's `sites.json` knows about, so another process can't add a fake row whose Open button points somewhere else.

### Changed
- The "reachable from your network" tooltip is now accurate for every bind address, not only "all interfaces".

## 1.0.0 (2026-10-30)

First public release.

- Menu bar count of running `node`, `bun` and `deno` dev servers (Python optional).
- Port, project folder, command, uptime and who started each server, including servers whose launcher has exited.
- Warning for servers reachable from the network.
- Open, Show Folder, and Stop with a Force Stop fallback that never signals a reused process ID.
- Notifications for new servers, and launch at login.
