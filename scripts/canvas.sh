#!/usr/bin/env bash
# Canvas via Claude - helper functions.
# Usage:  source scripts/canvas.sh
#
# Set CANVAS_HOST to your school's Canvas domain before sourcing, e.g.
#   export CANVAS_HOST="canvas.yourschool.edu"

set -u

BRIDGE_URL="${BRIDGE_URL:-http://127.0.0.1:8765/mcp/call}"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.staros-browser/api_token}"
CANVAS_HOST="${CANVAS_HOST:-}"
TAB="${TAB:-1}"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "ERROR: no API token at $TOKEN_FILE" >&2
  return 1 2>/dev/null || exit 1
fi
TOK=$(tr -d '\r\n' < "$TOKEN_FILE")

# bcall <tool_name> <json_args>
bcall() {
  curl -s -m 60 -X POST "$BRIDGE_URL" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $TOK" \
    -d "{\"name\":\"$1\",\"arguments\":$2}"
}

# List open tabs with their ids.
tabs() {
  bcall browser_get_tabs '{}' | python -c "
import sys, json
for t in json.load(sys.stdin).get('tabs', []):
    print(t['id'], '|', (t.get('title') or '')[:60], '|', (t.get('url') or '')[:90])
"
}

# go <url> - navigate the target tab and report where it landed.
go() {
  bcall browser_navigate "{\"url\":\"$1\",\"tab_id\":$TAB}" > /dev/null
  sleep 7
  bcall browser_get_page_info "{\"tab_id\":$TAB}" | python -c "
import sys, json
d = json.load(sys.stdin)
print('URL  :', d.get('url'))
print('TITLE:', d.get('title'))
"
}

# api <path> - hit a Canvas REST endpoint in the browser tab.
#   api '/courses?enrollment_state=active'
api() {
  if [ -z "$CANVAS_HOST" ]; then
    echo "ERROR: set CANVAS_HOST first" >&2
    return 1
  fi
  go "https://${CANVAS_HOST}/api/v1${1}"
}

# shot [filename] - full-page screenshot, image data stripped from the output.
shot() {
  local name="${1:-canvas.png}"
  bcall browser_screenshot \
    "{\"tab_id\":$TAB,\"save_to_file\":true,\"filename\":\"$name\",\"full_page\":true}" \
    | python -c "
import sys, json
d = json.load(sys.stdin)
for k in ('image', 'data', 'base64'):
    d.pop(k, None)
print(json.dumps(d)[:400])
"
}

echo "Loaded. Commands: tabs | go <url> | api <path> | shot [file]"
echo "CANVAS_HOST=${CANVAS_HOST:-<unset>}  TAB=$TAB"
