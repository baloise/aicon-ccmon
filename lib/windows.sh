# shellcheck shell=bash
# Stage 8: the Windows desktop widget (WSL only).
#
# The widget is a compiled executable, not a PowerShell script, and that is
# deliberate: Windows keys a tray icon's identity on (executable path + uID), so
# every powershell.exe-hosted icon collides with every other one. On this machine
# ours hashed onto a stale Citrix installer entry and could never get its own row
# in Settings > Taskbar - which is what "always show this icon" needs.
#
# csc.exe ships with the .NET Framework on every Windows box, so building it
# needs nothing installed.

CSC_CANDIDATES=(
  "/c/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
  "/c/Windows/Microsoft.NET/Framework/v4.0.30319/csc.exe"
)

stage_widget() {
  stage 8 "Windows widget"

  if [ "${IS_WSL:-0}" != 1 ]; then skip "not running under WSL"; return 0; fi
  if [ -z "${WIN_PROFILE:-}" ]; then skip "Windows profile not resolved"; return 0; fi

  local win_dir_win win_dir_unix
  win_dir_win="$WIN_PROFILE\\ccmon"
  win_dir_unix=$(wslpath -u "$win_dir_win" 2>/dev/null) || {
    skip "could not map $win_dir_win"; return 0; }
  mkdir -p "$win_dir_unix"

  # Retire the PowerShell widget this replaced.
  if [ -f "$win_dir_unix/ccmon-widget.ps1" ]; then
    need "an old PowerShell widget is still installed"
    confirm && { rm -f "$win_dir_unix/ccmon-widget.ps1"; fixed "removed it"; }
  fi

  local src_changed=0
  cmp -s "$CCMON_ROOT/widget/CcmonWidget.cs" "$win_dir_unix/CcmonWidget.cs" 2>/dev/null || src_changed=1
  install_file "$CCMON_ROOT/widget/CcmonWidget.cs" "$win_dir_unix/CcmonWidget.cs" 644 "widget source"

  local csc=""
  for c in "${CSC_CANDIDATES[@]}"; do [ -x "$c" ] && { csc="$c"; break; }; done
  if [ -z "$csc" ]; then
    fail "no csc.exe found - cannot build the widget"
    hint "It ships with the .NET Framework; check C:\\Windows\\Microsoft.NET\\Framework64"
    return 1
  fi

  if [ ! -f "$win_dir_unix/ccmon-widget.exe" ] || [ "$src_changed" = 1 ]; then
    need "widget needs building"
    if confirm; then
      local out
      out=$("$csc" /nologo /target:winexe /optimize+ \
              "/out:$win_dir_win\\ccmon-widget.exe" \
              /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll \
              /r:System.Web.Extensions.dll \
              "$win_dir_win\\CcmonWidget.cs" 2>&1 | tr -d '\r')
      if [ -f "$win_dir_unix/ccmon-widget.exe" ]; then
        fixed "built ccmon-widget.exe"
      else
        fail "build failed"
        [ -n "$out" ] && printf '%s\n' "$out" | head -5 | sed 's/^/        /'
        return 1
      fi
    fi
  else
    ok "widget is built and current"
  fi

  # Verify Windows can actually read the snapshot before wiring up autostart.
  local readable
  readable=$(powershell.exe -NoProfile -Command \
    "if (Test-Path '$UNC_PATH\\usage-snapshot.json') { 'yes' } else { 'no' }" 2>/dev/null | tr -d '\r\n')
  if [ "$readable" = "yes" ]; then
    ok "Windows can read the snapshot"
  else
    fail "Windows cannot read $UNC_PATH\\usage-snapshot.json"
    return 1
  fi

  # The tray menu opens the wallboard; prefer the published copy, since the local
  # server is only up while `ccmon serve` runs.
  WIDGET_URL=$(gh api "repos/$(git -C "$CCMON_ROOT" remote get-url origin 2>/dev/null \
      | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//')/pages" \
      --jq '.html_url' 2>/dev/null)
  [ -n "$WIDGET_URL" ] || WIDGET_URL="http://localhost:${CCMON_PORT:-8787}/"
  WIDGET_EXE="$win_dir_win\\ccmon-widget.exe"
  WIDGET_ARGS="--snapshot \"$UNC_PATH\\usage-snapshot.json\" --wallboard \"$WIDGET_URL\" --distro \"${WSL_DISTRO_NAME:-}\""

  widget_launcher "$win_dir_unix"
  widget_autostart
  widget_promote
  widget_process
}

# A double-clickable launcher, so the widget can be started without waiting for
# the next logon.
widget_launcher() {
  local dir=$1 want
  want=$(printf '@echo off\r\nstart "" "%s" %s\r\n' "$WIDGET_EXE" "$WIDGET_ARGS")
  if [ -f "$dir/ccmon-widget.cmd" ] && [ "$(cat "$dir/ccmon-widget.cmd")" = "$want" ]; then
    ok "launcher is current"
  else
    need "launcher needs writing"
    confirm && { printf '%s' "$want" > "$dir/ccmon-widget.cmd"; fixed "wrote ccmon-widget.cmd"; }
  fi
}

# Checking only that the shortcut exists would miss one still passing last
# version's arguments, so compare them.
widget_autostart() {
  local startup lnk have
  startup="$WIN_PROFILE\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"
  lnk=$(wslpath -u "$startup" 2>/dev/null)/ccmon.lnk
  [ -f "$lnk" ] && have=$(powershell.exe -NoProfile -Command \
      "\$s=(New-Object -ComObject WScript.Shell).CreateShortcut('$startup\\ccmon.lnk'); \$s.TargetPath + '|' + \$s.Arguments" \
      2>/dev/null | tr -d '\r\n')

  if [ "$have" = "$WIDGET_EXE|$WIDGET_ARGS" ]; then
    ok "starts automatically at logon"
    return 0
  fi
  if [ -n "$have" ]; then need "the Startup shortcut is out of date"
  else need "widget does not start at logon"; fi
  confirm || return 0
  powershell.exe -NoProfile -Command "
    \$s = (New-Object -ComObject WScript.Shell).CreateShortcut('$startup\\ccmon.lnk')
    \$s.TargetPath = '$WIDGET_EXE'
    \$s.Arguments = '$WIDGET_ARGS'
    \$s.WindowStyle = 7
    \$s.Save()" >/dev/null 2>&1 \
    && fixed "wrote the Startup shortcut" || fail "could not write the shortcut"
}

# Windows hides new tray icons by default. IsPromoted=1 is what the "Other system
# tray icons" toggle writes; the entry only exists once the icon has run at least
# once, so this is checked after the widget has been started before.
widget_promote() {
  local state
  state=$(powershell.exe -NoProfile -Command "
    \$k = Get-ChildItem 'HKCU:\\Control Panel\\NotifyIconSettings' -ErrorAction SilentlyContinue |
          Where-Object { (Get-ItemProperty \$_.PSPath).ExecutablePath -like '*ccmon-widget.exe' }
    if (-not \$k) { 'absent' }
    elseif ((Get-ItemProperty \$k.PSPath).IsPromoted -eq 1) { 'promoted' }
    else { 'hidden' }" 2>/dev/null | tr -d '\r\n')

  case "$state" in
    promoted) ok "tray icon is always visible" ;;
    hidden)
      need "tray icon is in the hidden overflow menu"
      confirm || return 0
      powershell.exe -NoProfile -Command "
        \$k = Get-ChildItem 'HKCU:\\Control Panel\\NotifyIconSettings' |
              Where-Object { (Get-ItemProperty \$_.PSPath).ExecutablePath -like '*ccmon-widget.exe' }
        Set-ItemProperty -Path \$k.PSPath -Name IsPromoted -Value 1 -Type DWord" >/dev/null 2>&1 \
        && fixed "pinned to the notification area" || fail "could not pin it"
      ;;
    *)
      info "Windows registers the tray icon on first run; it will be pinnable next pass."
      ;;
  esac
}

widget_process() {
  if widget_running; then
    ok "widget is running"
    info "On the desktop, behind your windows. Left-click the tray dot to toggle front/desktop."
  else
    need "widget is not running (the Startup shortcut only fires at logon)"
    confirm || return 0
    start_widget
    widget_running && fixed "widget started" || fail "widget did not start"
  fi
}

widget_running() {
  local n
  n=$(powershell.exe -NoProfile -Command \
      "@(Get-Process ccmon-widget -ErrorAction SilentlyContinue).Count" 2>/dev/null | tr -d '\r\n ')
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null
}

start_widget() {
  powershell.exe -NoProfile -Command \
    "Start-Process '$WIDGET_EXE' -ArgumentList '$WIDGET_ARGS'" >/dev/null 2>&1
  sleep 3
}

stop_widget() {
  powershell.exe -NoProfile -Command \
    "Get-Process ccmon-widget -ErrorAction SilentlyContinue | Stop-Process -Force" >/dev/null 2>&1
  sleep 1
}
