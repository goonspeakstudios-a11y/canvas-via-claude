#!/usr/bin/env bash
# Canvas via Claude - helper functions.
#
# Usage:  export CANVAS_HOST="canvas.yourschool.edu"
#         source scripts/canvas.sh
#
# This drives YOUR Firefox, already signed into YOUR Canvas account.
# Nothing here logs you in - you do that yourself in the browser window.

BRIDGE_URL="${BRIDGE_URL:-http://127.0.0.1:8765/mcp/call}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.staros-browser/api_token}"
CANVAS_HOST="${CANVAS_HOST:-}"
TAB="${TAB:-1}"

_err() { echo "ERROR: $*" >&2; }

# --- the bridge must be on this machine --------------------------------------
# Every call sends the API token as a header. If BRIDGE_URL is ever pointed
# somewhere else - a typo, a stale export, a copied snippet - that token leaves
# the machine. Refuse anything that is not loopback.
case "$BRIDGE_URL" in
  http://127.0.0.1:*|http://localhost:*|http://\[::1\]:*) ;;
  *) _err "BRIDGE_URL must be a loopback address, got: $BRIDGE_URL"
     return 1 2>/dev/null || exit 1 ;;
esac

# --- tab id must be a number -------------------------------------------------
case "$TAB" in
  ''|*[!0-9]*) _err "TAB must be a number, got: $TAB"
               return 1 2>/dev/null || exit 1 ;;
esac

# --- find python -------------------------------------------------------------
# Do not trust `command -v python3`. On Windows that usually resolves to the
# Microsoft Store app-execution stub, which exists, prints "Python was not
# found", and exits 49. Every candidate has to actually run something.
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

# The token is read from its file at call time and piped straight into curl as
# a config on stdin. It never appears in the command line (where any process
# running as you could read it out of the process list), never lands in a shell
# variable that later commands inherit, and is never copied to a temp file.
#
# A temp file was the obvious approach and was rejected: on Git Bash for Windows
# `chmod 600` silently does not stick - the file stays world-readable - so a
# "private" temp file would have been a false promise.
_auth() {
  printf 'header = "X-API-Key: %s"\n' "$(tr -d '\r\n' < "$TOKEN_FILE")"
}

# --- safe JSON ---------------------------------------------------------------
# Build request bodies with a real JSON encoder. Pasting a URL straight into a
# quoted string means any address containing a quote mark does not merely break
# the call - it can rewrite the rest of the request being sent to the bridge.
#
# _json key=value ...   values are strings, unless prefixed i: (int) or b: (bool)
_json() {
  "$PY" -c '
import sys, json
out = {}
for pair in sys.argv[1:]:
    k, _, v = pair.partition("=")
    if v.startswith("i:"):
        out[k] = int(v[2:])
    elif v.startswith("b:"):
        out[k] = (v[2:] == "true")
    else:
        out[k] = v
print(json.dumps(out))
' "$@"
}

# bcall <tool_name> <json_args>
#
# The common failure here is not an error - it is silence. The local server
# happily accepts and authenticates your call with no browser attached, then
# the request times out 30s later. Without this guard every helper below just
# pipes an empty string into python and prints a parse traceback, which tells
# you nothing about the actual problem (Firefox is closed).
bcall() {
  _out=$(_auth | curl -s -m 60 -X POST "$BRIDGE_URL" \
    --config - \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$1\",\"arguments\":$2}")

  if [ -z "$_out" ]; then
    _err "no response from the bridge at $BRIDGE_URL"
    _err "  is the local server running?  is Firefox open?   (try: check)"
    return 1
  fi
  case "$_out" in
    '{'*|'['*) ;;
    *) _err "bridge returned something that is not JSON:"
       printf '  %s\n' "$(printf '%s' "$_out" | head -c 200)" >&2
       return 1 ;;
  esac
  printf '%s' "$_out"
}

# check - preflight. Run this first when something is not working.
check() {
  printf 'bridge   : %s\n' "$BRIDGE_URL"
  if _auth | curl -s -m 5 --config - -o /dev/null "${BRIDGE_URL%/mcp/call}/health" 2>/dev/null; then
    printf 'server   : responding\n'
  else
    printf 'server   : NOT responding - the local bridge is not running\n'
    return 1
  fi
  if _out=$(bcall browser_get_tabs '{}' 2>/dev/null) && [ -n "$_out" ]; then
    printf 'firefox  : connected\n'
  else
    printf 'firefox  : not answering - open Firefox (the profile with the extension)\n'
    return 1
  fi
  printf 'python   : %s\n' "$PY"
}

# List open tabs with their ids.
tabs() {
  _out=$(bcall browser_get_tabs '{}') || return 1
  printf '%s' "$_out" | "$PY" -c "
import sys, json
for t in json.load(sys.stdin).get('tabs', []):
    print(t['id'], '|', (t.get('title') or '')[:60], '|', (t.get('url') or '')[:90])
"
}

# go <url> - navigate the target tab and report where it landed.
go() {
  if [ -z "${1:-}" ]; then _err "usage: go <url>"; return 1; fi
  bcall browser_navigate "$(_json url="$1" tab_id="i:$TAB")" > /dev/null || return 1
  sleep 7
  _out=$(bcall browser_get_page_info "$(_json tab_id="i:$TAB")") || return 1
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
  go "https://${CANVAS_HOST}/api/v1${1}"
}

# shot [filename] - full-page screenshot, image data stripped from the output.
shot() {
  _name="${1:-canvas.png}"
  # Reject a path outright rather than silently rewriting it, so you find out
  # the screenshot is not going where you asked.
  case "$_name" in
    ''|*/*|*\\*|*..*) _err "filename only, no path: $_name"; return 1 ;;
  esac
  # This sanitises the name on the way out. Whether the bridge itself confines
  # writes to its screenshot folder is the bridge's job - verify that before
  # trusting it with input you did not type.
  _out=$(bcall browser_screenshot \
    "$(_json tab_id="i:$TAB" save_to_file="b:true" filename="$_name" full_page="b:true")") \
    || return 1
  printf '%s' "$_out" | "$PY" -c "
import sys, json
d = json.load(sys.stdin)
for k in ('image', 'data', 'base64'):
    d.pop(k, None)
print(json.dumps(d)[:400])
"
}

echo "Loaded. Commands: tabs | go <url> | api <path> | shot [file]"
echo "CANVAS_HOST=${CANVAS_HOST:-<unset>}  TAB=$TAB  PY=$PY"
