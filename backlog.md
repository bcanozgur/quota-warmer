# QuotaWarmer Backlog

## Completed
- [x] Replace Claude Code and Codex provider icons with OpenUsage SVG assets.
- [x] Reduce the menubar popover from 544x560 to a compact 412x500 layout.
- [x] Move active/inactive red/green state to the menubar label only; remove sidebar status dots.
- [x] Rename the primary quota row from Session to 5h Window.
- [x] Remove Codex Reviews and Credits rows from the tool quota view.
- [x] Keep only 5h Window and Weekly quota bars for both Codex and Claude Code.
- [x] Prevent weekly reset data from being selected as the 5h window when reset is more than 24 hours away.
- [x] Show day-aware countdowns, including menubar labels such as 1d3h when needed.
- [x] Prefer active tools for automatic quota refreshes, avoiding inactive Claude keychain reads.
- [x] Make the footer next-update label clickable for manual refresh on the selected tool.
- [x] Show an hourglass indicator while quota refresh is running.
- [x] Move Warm into the selected tool screen and remove the footer Warm now button.
- [x] Simplify the main screen and remove the visible Polling label.
- [x] Make History collapsible and cap stored history at the latest 10 events.
- [x] Shorten System and Privacy settings, using info hover text for detail.
- [x] Switch quota bars and labels from used quota to remaining quota across the app.
- [x] Add Active/Passive control inside each provider submenu, separate from manual Warm.
- [x] Reduce the menubar provider icon size so it matches the compact OpenUsage-style tray label.
- [x] Replace large main-screen provider cards with a compact provider list and small remaining-quota bars.
- [x] Scale the popover UI to 70% of the prior panel size.
- [x] Restore provider glyphs in the menubar label using a constrained template/raster image instead of raw SVG rendering.

## Follow-up
- [ ] Manually verify the installed menu bar extra with real Codex quota data after launch.
- [ ] Re-check Claude Code quota UI when Claude membership/credentials are available.
- [ ] Monitor whether macOS Keychain still prompts after allowing QuotaWarmer access once.
- [ ] Treat `quic_conn_keepalive_handler` and `nw_read_request_report` Xcode logs as network timeout noise unless quota fetches fail visibly in the UI.
