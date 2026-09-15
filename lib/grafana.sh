# shellcheck shell=bash
# Stages 6 and 7: the Grafana Cloud credential, and a live push test.
#
# Grafana is OPTIONAL and opt-in. History is kept in git regardless, and the
# ingest token needs a request to the platform team, so an unconfigured Grafana
# is a normal steady state - not an outstanding task to nag about every run.
# `./ccmon grafana` starts the walkthrough when someone actually wants it.
#
# When it does run, this stage is the ONLY place that explains how to obtain the
# token. There is deliberately no example env file and no setup chapter in the
# README: whatever a human needs to know is printed here, when it is needed.

# No built-in defaults: the endpoint region, the instance id and the account
# label are specific to whoever is running this.
DEFAULT_OTLP_ENDPOINT="https://otlp-gateway-prod-<region>.grafana.net/otlp/v1/metrics"
DEFAULT_OTLP_USER=""
DEFAULT_ACCOUNT="default"

stage_token() {
  stage 6 "Grafana Cloud push"

  if [ -r "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    ( . "$ENV_FILE"; [ -n "${GRAFANA_OTLP_TOKEN:-}" ] && [ -n "${GRAFANA_OTLP_ENDPOINT:-}" ] ) \
      && { ok "credential present at $ENV_FILE"
           [ "$(stat -c '%a' "$ENV_FILE")" = "600" ] \
             && ok "permissions are 0600" \
             || { need "permissions are not 0600"
                  confirm && { chmod 600 "$ENV_FILE"; fixed "tightened to 0600"; }; }
           return 0; }
    need "$ENV_FILE exists but is incomplete"
  elif [ "${WANT_GRAFANA:-0}" != 1 ]; then
    # Not configured, and nobody asked for it: that is fine, not a finding.
    skip "not configured (optional) - ./ccmon grafana to set it up"
    return 0
  else
    need "not configured yet"
  fi

  if [ "$MODE" = status ]; then
    info "run ./ccmon grafana to be walked through creating it"
    return 0
  fi
  # The walkthrough needs a human to paste a secret.
  if [ ! -t 0 ]; then
    info "run ./ccmon grafana from a terminal to be walked through creating it"
    return 0
  fi

  cat <<EXPLAIN

        Optional. History is already kept in this repo; pushing the same
        samples to Grafana Cloud additionally gets you its dashboards and
        alerting. To do that it needs an ingest token.

        Two DIFFERENT logins are involved - this trips people up:

          - https://<stack>.grafana.net  is the stack you view dashboards in.
            It is behind corporate Entra SSO.
          - https://grafana.com          is Grafana Labs' portal, a separate
            account system, and the only place access policies are created.
            Entra SSO may not apply there at all.

        The token you need is a Cloud Access Policy token with scope
        metrics:write, minted at grafana.com -> Access Policies. Creating one
        requires Admin on the Grafana Labs org, so if you are a regular member
        you will need to ask whoever runs the stack.

        In an organisation that already runs Grafana Cloud, a token like this
        usually exists and is held by whoever owns the stack - ask them rather
        than minting a second one.

        This is NOT a Grafana service-account token. Those are dashboard API
        tokens and cannot write metrics.

        Leave this blank to skip; ccmon keeps working locally either way.

EXPLAIN

  confirm || { info "skipped - history still goes to git; only the Grafana copy is missing"; return 0; }

  local endpoint user account token
  endpoint=$(ask_value "OTLP endpoint" "$DEFAULT_OTLP_ENDPOINT")
  user=$(ask_value     "OTLP instance ID (username)" "$DEFAULT_OTLP_USER")
  account=$(ask_value  "account label for the series" "$DEFAULT_ACCOUNT")
  token=$(ask_secret   "access policy token (input hidden)")

  if [ -z "$token" ]; then
    fail "no token entered - nothing written"
    return 1
  fi

  mkdir -p "$CCMON_DIR"
  local tmp="$ENV_FILE.$$"
  ( umask 077; cat > "$tmp" <<EOF
# Written by ccmon. Never commit this file.
GRAFANA_OTLP_ENDPOINT=$endpoint
GRAFANA_OTLP_USER=$user
GRAFANA_OTLP_TOKEN=$token
CCMON_ACCOUNT=$account
EOF
  )
  mv -f "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  fixed "wrote $ENV_FILE (0600)"
}

stage_push() {
  if [ ! -r "$ENV_FILE" ]; then
    return 0   # nothing configured, nothing to test, nothing to say
  fi
  stage 7 "Grafana push test"

  "$CCMON_DIR/usage-poll.sh" 2>/dev/null || true

  if [ ! -f "$PUSH_LOG" ]; then
    fail "the poller produced no push result"
    return 1
  fi

  local when code body
  when=$(head -1 "$PUSH_LOG" | cut -f1)
  code=$(head -1 "$PUSH_LOG" | cut -f2)
  body=$(tail -n +2 "$PUSH_LOG")

  case "$code" in
    200)
      ok "push accepted ($when)"
      [ -n "$body" ] && [ "$body" != '{"partialSuccess":{}}' ] && info "$body"
      info "Query claude_usage_five_hour_percent on your Grafana stack"
      ;;
    401|403)
      fail "push rejected: HTTP $code - the token is wrong or lacks metrics:write"
      hint "Delete $ENV_FILE and re-run ./ccmon to enter a new one."
      ;;
    000|"")
      fail "push could not connect"
      offer_proxy_env
      ;;
    *)
      fail "push returned HTTP $code"
      [ -n "$body" ] && info "$body"
      ;;
  esac
}

# The systemd unit inherits no environment, so a laptop that needs the corporate
# proxy will poll fine (api.anthropic.com works direct) but fail to push.
offer_proxy_env() {
  local proxy="${https_proxy:-${HTTPS_PROXY:-}}"
  [ -n "$proxy" ] || return 0
  local drop="$UNIT_DIR/claude-usage.service.d"
  if [ -f "$drop/proxy.conf" ]; then
    ok "proxy override already present"
    return 0
  fi
  need "your shell uses a proxy but the systemd unit does not inherit it"
  confirm || return 0
  mkdir -p "$drop"
  cat > "$drop/proxy.conf" <<EOF
[Service]
Environment=https_proxy=$proxy
Environment=http_proxy=$proxy
Environment=no_proxy=${no_proxy:-localhost,127.0.0.1}
EOF
  systemctl --user daemon-reload
  fixed "wrote $drop/proxy.conf"
}
