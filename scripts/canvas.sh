#!/usr/bin/env bash
# Canvas via Claude - helper functions.
#
# Usage:  export CANVAS_HOST="canvas.yourschool.edu"
#         source scripts/canvas.sh
#         check
#
# This drives YOUR Firefox, already signed into YOUR Canvas account.
# Nothing here logs you in - you do that yourself in the browser window.
#
# Tests: bash tests/run_tests.sh   (no Firefox needed)

BRIDGE_URL="${BRIDGE_URL:-http://127.0.0.1:8765/mcp/call}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.staros-browser/api_token}"
CANVAS_HOST="${CANVAS_HOST:-}"
TAB="${TAB:-1}"

_err() { echo "ERROR: $*" >&2; }

# --- the bridge must be on this machine --------------------------------------
# Every call sends the API token as a header, so this address decides where the
# token goes. Checked on EVERY call, not once at load: BRIDGE_URL is a plain
# variable that any later command can reassign, and the token is read fresh at
# call time - so a load-time-only check guards the one moment the value is not
# actually in use.
#
# The host is parsed out rather than glob-matched. `http://127.0.0.1:8765@evil.com/`
# starts with "http://127.0.0.1:" and passes a naive prefix test, but curl reads
# everything before the "@" as user:password and connects to evil.com.
_check_bridge_url() {
  case "$BRIDGE_URL" in
    http://*) ;;
    *) _err "BRIDGE_URL must be a plain http loopback address, got: $BRIDGE_URL"
       return 1 ;;
  esac

  _hp=${BRIDGE_URL#http://}   # strip scheme
  _hp=${_hp%%/*}              # drop path
  _hp=${_hp%%\?*}             # drop query
  _hp=${_hp%%#*}              # drop fragment

  case "$_hp" in
    *@*) _err "BRIDGE_URL is not loopback: everything before '@' is credentials,"
         _err "  so the real host is '${_hp##*@}'. Refusing to send the token there."
         return 1 ;;
  esac

  case "$_hp" in
    \[*\]*) _h=${_hp%%\]*}; _h=${_h#\[} ;;   # [::1]:8765
    *)      _h=${_hp%%:*} ;;
  esac

  case "$_h" in
    127.0.0.1|localhost|::1) return 0 ;;
    *) _err "BRIDGE_URL must be a loopback address, got host: $_h"; return 1 ;;
  esac
}

_check_tab() {
  case "$TAB" in
    ''|*[!0-9]*) _err "TAB must be a number, got: $TAB"; return 1 ;;
  esac
}

# Fail fast at load, but _check_bridge_url runs again on every call.
_check_bridge_url || return 1 2>/dev/null || exit 1

# --- find python -------------------------------------------------------------
# Do not trust `command -v python3`. On Windows that usually resolves to the
# Microsoft Store app-execution stub, which exists on PATH, prints "Python was
# not found", and exits 49. Every candidate has to actually run something.
PY="${PY:-}"
if [ -z "$PY" ]; then
  for _c in python3 python py /c/Python314/python.exe; do
    if command -v "$_c" >/dev/null 2>&1 && "$_c" -c 'pass' >/dev/null 2>&1; then
      PY="$_c"; break
    fi
  done
fi
if [ -z "$PY" ]; then
  _err "no working python found (set PY=/path/to/python)"
  return 1 2>/dev/null || exit 1
fi

# --- token -------------------------------------------------------------------
if [ ! -f "$TOKEN_FILE" ]; then
  _err "no API token at $TOKEN_FILE"
  return 1 2>/dev/null || exit 1
fi

# The token is read from its file at call time and piped into curl as a config
# on stdin. It never appears in the command line (where any process running as
# you could read it from the process list), never lands in a shell variable
# later commands inherit, and is never copied to a temp file.
#
# A temp file was the obvious approach and was rejected after testing: on Git
# Bash for Windows `chmod 600` silently does not stick, so a "private" temp
# file would have been a false promise.
_auth() {
  printf 'header = "X-API-Key: %s"\n' "$(tr -d '\r\n' < "$TOKEN_FILE")"
}

# --- safe JSON ---------------------------------------------------------------
# _json <key> <type> <value> ...     type: s (string) | i (int) | b (bool)
#
# Types are declared per key rather than sniffed from the value. Sniffing meant
# a real filename like "b:report.png" was silently coerced to the boolean false,
# and the screenshot went somewhere the user was never told about.
_json() {
  "$PY" -c '
import sys, json
a = sys.argv[1:]
if len(a) % 3:
    print("internal: _json takes key type value triples", file=sys.stderr)
    sys.exit(1)
out = {}
for i in range(0, len(a), 3):
    k, t, v = a[i], a[i + 1], a[i + 2]
    if t == "i":
        try:
            out[k] = int(v)
        except ValueError:
            print("%s must be a number, got: %s" % (k, v), file=sys.stderr)
            sys.exit(1)
    elif t == "b":
        out[k] = (v == "true")
    else:
        out[k] = v
print(json.dumps(out))
' "$@"
}

# --- response checking -------------------------------------------------------
# The failure that matters is NOT silence. With Firefox closed the bridge waits
# 30s and then answers HTTP 200 with well-formed JSON:
#
#   {"success": false, "error": "Command getTabs timed out ... after 30s"}
#
# So "did I get JSON back" is not a success test. Every real failure - dead
# browser, stale token, unknown tool, malformed body - arrives as parseable
# JSON, and a client that does not read the body reports all of them as fine.
_check_response() {  # stdin = body, $1 = http status
  "$PY" -c '
import sys, json
status = sys.argv[1]
raw = sys.stdin.read()

if not raw.strip():
    sys.stderr.write("no response from the bridge - is the local server running?\n")
    sys.exit(1)

try:
    d = json.loads(raw)
except ValueError:
    sys.stderr.write("bridge returned non-JSON (HTTP %s): %s\n" % (status, raw[:200]))
    sys.exit(1)

if status not in ("200", "201"):
    msg = d.get("error") if isinstance(d, dict) else raw[:200]
    sys.stderr.write("bridge returned HTTP %s: %s\n" % (status, msg))
    if status == "403":
        sys.stderr.write("  the token was rejected - check TOKEN_FILE\n")
    sys.exit(1)

if isinstance(d, dict) and (d.get("success") is False or d.get("error")):
    msg = str(d.get("error") or "unknown error")
    sys.stderr.write("bridge reported failure: %s\n" % msg)
    if "timed out" in msg.lower():
        sys.stderr.write("  the server is up but Firefox is not answering.\n")
        sys.stderr.write("  Open Firefox (the profile with the extension), then retry.\n")
    sys.exit(1)
' "$1"
}

# bcall <tool_name> <json_args>
bcall() {
  _check_bridge_url || return 1
  _check_tab || return 1
  if [ -z "${2:-}" ]; then
    _err "internal: empty arguments for tool '$1' (did _json fail?)"
    return 1
  fi

  _raw=$(_auth | curl -s -m 60 -w '\n%{http_code}' -X POST "$BRIDGE_URL" \
    --config - \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$1\",\"arguments\":$2}")

  _status="${_raw##*$'\n'}"
  _body="${_raw%$'\n'*}"

  printf '%s' "$_body" | _check_response "$_status" || return 1
  printf '%s' "$_body"
}

# check - preflight. Run this first when something is not working.
check() {
  printf 'bridge   : %s\n' "$BRIDGE_URL"
  _check_bridge_url || return 1

  if _auth | curl -s -m 5 --fail --config - -o /dev/null "${BRIDGE_URL%/mcp/call}/health"; then
    printf 'server   : responding\n'
  else
    printf 'server   : NOT responding - the local bridge is not running\n'
    return 1
  fi

  # Ask the browser something and read the answer. /health cannot tell you this:
  # it is unauthenticated, and its browsers_connected counts WebSocket clients
  # only - it reads 0 even when the extension is fully attached by long-poll.
  if bcall browser_get_tabs "$(_json)" >/dev/null 2>&1; then
    printf 'firefox  : connected\n'
  else
    printf 'firefox  : not answering - open Firefox (the profile with the extension)\n'
    return 1
  fi

  printf 'python   : %s\n' "$PY"
  printf 'tab      : %s\n' "$TAB"
}

# List open tabs with their ids.
tabs() {
  _a=$(_json) || return 1
  _out=$(bcall browser_get_tabs "$_a") || return 1
  printf '%s' "$_out" | "$PY" -c "
import sys, json
for t in json.load(sys.stdin).get('tabs', []):
    print(t['id'], '|', (t.get('title') or '')[:60], '|', (t.get('url') or '')[:90])
"
}

# go <url> - navigate the target tab and report where it landed.
go() {
  if [ -z "${1:-}" ]; then _err "usage: go <url>"; return 1; fi
  _a=$(_json url s "$1" tab_id i "$TAB") || return 1
  bcall browser_navigate "$_a" > /dev/null || return 1
  sleep 7
  _a=$(_json tab_id i "$TAB") || return 1
  _out=$(bcall browser_get_page_info "$_a") || return 1
  printf '%s' "$_out" | "$PY" -c "
import sys, json
d = json.load(sys.stdin)
print('URL  :', d.get('url'))
print('TITLE:', d.get('title'))
"
}

# api <path> - hit a Canvas REST endpoint in the browser tab.
#   api '/courses?enrollment_state=active'
api() {
  if [ -z "$CANVAS_HOST" ]; then _err "set CANVAS_HOST first"; return 1; fi
  if [ -z "${1:-}" ]; then _err "usage: api <path>"; return 1; fi
  case "$1" in
    /*) ;;
    *) _err "api path must start with /, got: $1"; return 1 ;;
  esac
  go "https://${CANVAS_HOST}/api/v1${1}"
}

# shot [filename] - full-page screenshot, image data stripped from the output.
shot() {
  _name="${1:-canvas.png}"
  # Reject a path outright rather than silently rewriting it, so you find out
  # when the screenshot is not going where you asked.
  case "$_name" in
    ''|*/*|*\\*|*..*) _err "filename only, no path: $_name"; return 1 ;;
  esac
  # This sanitises the name on the way out. Whether the bridge itself confines
  # writes to its screenshot folder is the bridge's job - verify that before
  # trusting it with input you did not type.
  _a=$(_json tab_id i "$TAB" save_to_file b true filename s "$_name" full_page b true) || return 1
  _out=$(bcall browser_screenshot "$_a") || return 1
  printf '%s' "$_out" | "$PY" -c "
import sys, json
d = json.load(sys.stdin)
for k in ('image', 'data', 'base64'):
    d.pop(k, None)
print(json.dumps(d)[:400])
"
}

echo "Loaded. Commands: check | tabs | go <url> | api <path> | shot [file]"
echo "Run 'check' first.  CANVAS_HOST=${CANVAS_HOST:-<unset>}  TAB=$TAB  PY=$PY"
