#!/bin/zsh
# Prints QuotaWarmer's live quota as one line, for Claude Code's statusLine,
# tmux's status-right or a starship custom module:
#
#   Claude 58% left · 2h13m | Codex 82% used · 4h01m
#
# Reads ~/Library/Application Support/QuotaWarmer/status.json, which the app
# rewrites after every successful quota fetch. Data older than 5 minutes is
# marked "(stale 12m)". Always exits 0 so a missing file never breaks a prompt.
#
# Options:
#   --file PATH             read another status file ($QUOTAWARMER_STATUS_FILE)
#   --only claude,codex     only these tools or account ids (claude.work)
#   --pinned                only accounts pinned to the menu bar
#   --weekly                also show the weekly window ("wk 31%")
#   --mode used|remaining   override each account's display mode
#   --stale-after SECONDS   when to mark data stale (default 300)
#
# Parsing uses JavaScript for Automation, which every macOS ships (jq only
# ships from macOS 15). Claude Code's JSON on stdin is ignored.

exec /usr/bin/osascript -l JavaScript - "$@" <<'JS'
ObjC.import("Foundation");

function compactTime(secs) {
  var total = Math.max(0, Math.floor(secs));
  var d = Math.floor(total / 86400);
  var h = Math.floor((total % 86400) / 3600);
  var m = Math.floor((total % 3600) / 60);
  if (d > 0) return d + "d" + h + "h";
  return h > 0 ? h + "h" + (m < 10 ? "0" : "") + m + "m" : m + "m";
}

function percent(win, mode) {
  return mode === "used" ? win.usedPercent : win.remainingPercent;
}

function suffix(mode) { return mode === "used" ? "used" : "left"; }

// Mirrors the app's menu-bar text for the 5-hour window.
function sessionText(win, mode, now) {
  var reset = win.resetAt ? Date.parse(win.resetAt) : null;
  if (win.idle) return percent(win, mode) + "% " + suffix(mode);
  if (reset !== null && reset <= now) {
    // The window reset since the last fetch: quota is (about) restored.
    return "~" + (mode === "used" ? 0 : 100) + "% " + suffix(mode);
  }
  if (win.settling && reset !== null) return compactTime((reset - now) / 1000);
  var text = percent(win, mode) + "% " + suffix(mode);
  if (reset !== null) text += " · " + compactTime((reset - now) / 1000);
  return text;
}

function providerText(p, opts, now) {
  var mode = opts.mode || p.displayMode;
  var fetched = p.fetchedAt ? Date.parse(p.fetchedAt) : null;
  if (fetched === null || (!p.session && !p.weekly)) return p.name + " --";
  var parts = [];
  if (p.session) parts.push(sessionText(p.session, mode, now));
  if (opts.weekly && p.weekly) {
    var weeklyReset = p.weekly.resetAt ? Date.parse(p.weekly.resetAt) : null;
    var weekly = weeklyReset !== null && weeklyReset <= now
      ? "~" + (mode === "used" ? 0 : 100)
      : percent(p.weekly, mode);
    parts.push("wk " + weekly + "%");
  }
  if (parts.length === 0) parts.push("--");
  var text = p.name + " " + parts.join(" · ");
  var age = (now - fetched) / 1000;
  if (age > opts.staleAfter) text += " (stale " + compactTime(age) + ")";
  return text;
}

function run(argv) {
  var env = $.NSProcessInfo.processInfo.environment;
  var envFile = env.objectForKey("QUOTAWARMER_STATUS_FILE");
  var opts = {
    file: envFile.isNil() ? null : envFile.js,
    only: null, pinned: false, weekly: false, mode: null, staleAfter: 300
  };
  for (var i = 0; i < argv.length; i++) {
    var arg = argv[i];
    if (arg === "--file") opts.file = argv[++i];
    else if (arg === "--only") opts.only = (argv[++i] || "").split(",");
    else if (arg === "--pinned") opts.pinned = true;
    else if (arg === "--weekly") opts.weekly = true;
    else if (arg === "--mode") opts.mode = argv[++i] === "used" ? "used" : "remaining";
    else if (arg === "--stale-after") opts.staleAfter = Number(argv[++i]) || 300;
  }
  if (!opts.file) {
    opts.file = $.NSHomeDirectory().js + "/Library/Application Support/QuotaWarmer/status.json";
  }

  var raw = $.NSString.stringWithContentsOfFileEncodingError(opts.file, $.NSUTF8StringEncoding, null);
  if (raw.isNil()) return "QuotaWarmer: no data";
  var status;
  try { status = JSON.parse(raw.js); } catch (e) { return "QuotaWarmer: unreadable status"; }
  if (status.schemaVersion !== 1) return "QuotaWarmer: update the statusline script";

  var now = Date.now();
  var lines = (status.providers || []).filter(function (p) {
    if (p.mode === "off") return false;
    if (opts.pinned && !p.pinned) return false;
    if (opts.only && opts.only.indexOf(p.id) < 0 && opts.only.indexOf(p.tool) < 0) return false;
    return true;
  }).map(function (p) { return providerText(p, opts, now); });
  return lines.length ? lines.join(" | ") : "QuotaWarmer: no data";
}
JS
