# shellcheck shell=bash
# Stage 6 on macOS: the desktop widget. lib/windows.sh is the same stage on WSL,
# and ./ccmon picks between them - neither lib knows about the other.
#
# The widget is a compiled binary in an .app bundle. The bundle is not strictly
# needed to make a status item work, but it is what makes it stable: LSUIElement
# in Info.plist makes the process accessory before any of our code runs, so
# there is no Dock-icon flicker, and codesign signs bundles rather than loose
# executables.

WIDGET_AGENT="com.ccmon.widget"
WIDGET_APP="$CCMON_DIR/CcmonWidget.app"
WIDGET_BIN="$WIDGET_APP/Contents/MacOS/CcmonWidget"
WIDGET_SRC="$CCMON_DIR/CcmonWidget.swift"
WIDGET_PLIST="$HOME/Library/LaunchAgents/$WIDGET_AGENT.plist"
WIDGET_UPDATE="$CCMON_DIR/ccmon-update.command"

# The wallboard URL and the repo path end up inside XML. A Pages URL will not
# contain a metacharacter; a repo path could.
xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

stage_macos_widget() {
  stage 6 "Desktop widget"

  if ! command -v swiftc >/dev/null 2>&1; then
    fail "no swiftc - cannot build the widget"
    hint "The Command Line Tools provide it: xcode-select --install"
    return 1
  fi

  mkdir -p "$WIDGET_APP/Contents/MacOS"
  install_file "$CCMON_ROOT/widget/CcmonWidget.swift" "$WIDGET_SRC" 644 "widget source"
  install_file "$CCMON_ROOT/widget/Info.plist" "$WIDGET_APP/Contents/Info.plist" 644 "widget Info.plist"

  # Resolved before the build rather than just before the LaunchAgent is
  # written: a rebuild has to stop the running widget, and cannot start it again
  # without its arguments. The menu opens the wallboard; prefer the published
  # copy, since the local server is only up while `ccmon serve` runs.
  WIDGET_URL=$(wallboard_url)

  widget_build || return 1
  widget_updater
  widget_autostart
  widget_process
}

widget_build() {
  # Against the built binary, never the repo source: install_file has already
  # synced the source by now, so comparing those two would call the widget
  # current the moment it was copied, even if the build that should have
  # followed never ran. Info.plist counts too - it is inside the signature.
  if [ -x "$WIDGET_BIN" ] \
     && [ ! "$WIDGET_SRC" -nt "$WIDGET_BIN" ] \
     && [ ! "$WIDGET_APP/Contents/Info.plist" -nt "$WIDGET_BIN" ]; then
    ok "widget is built and current"
    return 0
  fi

  need "widget needs building"
  confirm || { info "left unchanged"; return 0; }

  local was_running=0
  if widget_running; then was_running=1; stop_widget; fi

  # The old binary survives a failed build, so "the file exists" proves nothing;
  # only a changed mtime distinguishes a build from a no-op.
  local before out
  before=$(file_mtime "$WIDGET_BIN")
  info "compiling - this takes a few seconds"
  # -target pins a deployment floor because the Command Line Tools SDK runs
  # ahead of the OS: without it the compiler accepts an API that is not there
  # at runtime. No -O; the build happens in front of you and the widget repaints
  # twice a minute, so compile time is the only cost anyone here can feel.
  out=$(swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
          -o "$WIDGET_BIN" "$WIDGET_SRC" 2>&1)
  if [ ! -x "$WIDGET_BIN" ] || [ "$(file_mtime "$WIDGET_BIN")" = "$before" ]; then
    fail "build failed"
    [ -n "$out" ] && printf '%s\n' "$out" | head -5 | sed 's/^/        /'
    [ "$was_running" = 1 ] && start_widget      # better the old widget than none
    return 1
  fi

  # Re-signing is a build step, not a security step. Gatekeeper never sees this
  # app - it triggers on the quarantine xattr, which a file swiftc writes does
  # not carry. But once the bundle is signed, replacing the executable without
  # re-signing leaves CodeResources describing a file that is gone, and on
  # Apple silicon the app is then killed at launch with a message that blames
  # nothing at all.
  if codesign --force --sign - "$WIDGET_APP" >/dev/null 2>&1; then
    fixed "built and signed CcmonWidget.app"
  else
    fail "built, but could not sign it - it will not launch on Apple silicon"
  fi
  [ "$was_running" = 1 ] && start_widget
  return 0
}

# "Update ccmon" cannot just spawn a shell from inside the widget: ./ccmon
# update reaches this stage, which boots the widget's own job out, and launchd
# tears down the whole process group - including the shell running the update.
# Handing a .command to Terminal puts it in a process tree launchd is not about
# to kill, and the window it opens is the progress report.
widget_updater() {
  local want
  want=$(printf '#!/bin/bash\n# Written by ccmon. The widget menu opens this.\ncd %s && ./ccmon update --yes\n' "$(printf '%q' "$CCMON_ROOT")")
  if [ -f "$WIDGET_UPDATE" ] && [ "$(cat "$WIDGET_UPDATE")" = "$want" ]; then
    ok "update command is current"
    return 0
  fi
  need "update command needs writing"
  confirm || return 0
  printf '%s' "$want" > "$WIDGET_UPDATE"
  chmod 755 "$WIDGET_UPDATE"
  fixed "wrote ccmon-update.command"
}

# Unlike the poller's agent this plist carries per-install paths, so it is
# generated rather than copied. The whole file is compared, which subsumes "the
# arguments drifted" and also catches a hand-edited KeepAlive.
widget_autostart() {
  local tmp="$WIDGET_PLIST.ccmon.$$"
  mkdir -p "$HOME/Library/LaunchAgents"
  # Straight to a file rather than into a variable: it lets plutil check the
  # result before it is installed, and bash 3.2 - which is what /bin/bash is on
  # every Mac - mis-parses a heredoc inside a command substitution.
  cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by ccmon. Edit ./ccmon, not this. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$WIDGET_AGENT</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$WIDGET_BIN")</string>
    <string>--snapshot</string>  <string>$(xml_escape "$SNAPSHOT")</string>
    <string>--wallboard</string> <string>$(xml_escape "$WIDGET_URL")</string>
    <string>--poller</string>    <string>$(xml_escape "$CCMON_DIR/usage-poll.sh")</string>
    <string>--update</string>    <string>$(xml_escape "$WIDGET_UPDATE")</string>
    <string>--refresh</string>   <string>30</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <!--
    The dictionary form, not KeepAlive true. With true, Quit relaunches the
    widget within a second and the menu item looks broken; with this, a clean
    exit stays dead until the next login while a crash is restarted - which is
    what the Windows Startup shortcut amounts to.

    It is also why a rebuild stops the widget with bootout rather than pkill: a
    signalled exit is an unsuccessful one, so pkill would hand the job straight
    back to launchd in the middle of the build.
  -->
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <!-- A status item in a non-GUI session is a crash waiting to happen. -->
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <!-- Keep the launchd resource policy from treating a widget as a batch job. -->
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

  if [ -f "$WIDGET_PLIST" ] && cmp -s "$tmp" "$WIDGET_PLIST"; then
    rm -f "$tmp"
    ok "starts automatically at login"
    return 0
  fi
  if [ -f "$WIDGET_PLIST" ]; then need "the widget LaunchAgent is out of date"
  else need "widget does not start at login"; fi
  if ! confirm; then rm -f "$tmp"; return 0; fi

  if ! plutil -lint "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "generated an invalid plist - not installing it"
    return 1
  fi
  mv -f "$tmp" "$WIDGET_PLIST"

  launchctl enable "gui/$(id -u)/$WIDGET_AGENT" 2>/dev/null
  launchctl bootout "gui/$(id -u)/$WIDGET_AGENT" >/dev/null 2>&1
  if launchctl bootstrap "gui/$(id -u)" "$WIDGET_PLIST" 2>&1 | sed 's/^/        /'; then
    fixed "wrote and loaded the LaunchAgent"
  else
    fail "could not load the LaunchAgent"
  fi
}

widget_process() {
  if widget_running; then
    ok "widget is running"
    info "On the desktop, behind your windows. Left-click the menu bar dot to toggle front/desktop."
  else
    need "widget is not running"
    confirm || return 0
    start_widget
    widget_running && fixed "widget started" || fail "widget did not start"
  fi
  # The Windows stage can pin its tray icon with IsPromoted=1. There is no
  # equivalent here, and on a notched Mac with a busy menu bar ours can end up
  # under the notch with nothing an installer can do about it.
  if [ ! -f "$SNAPSHOT" ]; then
    info "no snapshot yet - the widget will say so until the poller's first run"
  fi
}

widget_running() { pgrep -x CcmonWidget >/dev/null 2>&1; }

start_widget() {
  launchctl kickstart "gui/$(id -u)/$WIDGET_AGENT" >/dev/null 2>&1 \
    || { [ -f "$WIDGET_PLIST" ] && launchctl bootstrap "gui/$(id -u)" "$WIDGET_PLIST" >/dev/null 2>&1; }
  sleep 2
}

# bootout, not pkill - see the KeepAlive comment in widget_autostart. The pkill
# afterwards is for a copy started by hand, which launchd has no job for.
stop_widget() {
  local i=0
  launchctl bootout "gui/$(id -u)/$WIDGET_AGENT" >/dev/null 2>&1
  pkill -x CcmonWidget >/dev/null 2>&1
  while [ "$i" -lt 6 ]; do
    widget_running || break
    sleep 1; i=$(( i + 1 ))
  done
}
