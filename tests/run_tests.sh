#!/usr/bin/env bash
# Tests for scripts/canvas.sh, run against tests/mock_bridge.py.
#
#   bash tests/run_tests.sh
#
# No Firefox and no real bridge required. The mock reproduces the response
# shapes that actually matter - in particular that a closed browser answers
# HTTP 200 with valid JSON rather than going silent.

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PORT="${PORT:-8799}"
TOKEN="test-token-abc123"
TOKFILE="$HERE/.test_token"

PY=""
for c in python3 python py /c/Python314/python.exe; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "no working python found"; exit 1; }

printf '%s' "$TOKEN" > "$TOKFILE"

PASS=0
FAIL=0
MOCK_PID=""

start_mock() {  # start_mock <mode>
  stop_mock
  "$PY" "$HERE/mock_bridge.py" "$PORT" "$1" "$TOKEN" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT/health" && return 0
    sleep 0.3
  done
  echo "mock failed to start"; exit 1
}

stop_mock() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  MOCK_PID=""
}

trap 'stop_mock; rm -f "$TOKFILE"' EXIT

# ok <name> <condition-description> ; reads $? style via explicit call
check_that() {  # check_that <name> <0|1 result> ; 0 = pass
  if [ "$2" -eq 0 ]; then
    printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1))
  fi
}

# Run a snippet with canvas.sh sourced. Prints combined output; exit code is
# the snippet's.
in_shell() {  # in_shell <extra-env> <snippet>
  env $1 BRIDGE_URL="http://127.0.0.1:$PORT/mcp/call" TOKEN_FILE="$TOKFILE" \
    bash -c "cd '$ROOT'; source scripts/canvas.sh >/dev/null 2>&1; $2" 2>&1
}

echo
echo "=== A. Firefox closed (bridge answers 200 + JSON error) ==="
start_mock closed

out=$(in_shell "" 'tabs'); rc=$?
echo "$out" | grep -qiE "timed out|not answering|error" && [ "$rc" -ne 0 ]
check_that "tabs fails loudly instead of printing nothing and exiting 0" $?

out=$(in_shell "" 'check'); rc=$?
{ ! echo "$out" | grep -qi "firefox  *: *connected"; } && [ "$rc" -ne 0 ]
check_that "check does NOT claim firefox is connected" $?

out=$(in_shell "" 'go https://canvas.example.edu'); rc=$?
{ ! echo "$out" | grep -q "URL  : None"; } && [ "$rc" -ne 0 ]
check_that "go does not print 'URL  : None' and swallow the failure" $?

echo
echo "=== B. Bad token (403) ==="
start_mock unauthorized
out=$(in_shell "" 'tabs'); rc=$?
[ "$rc" -ne 0 ]
check_that "tabs fails on 403 Unauthorized" $?

echo
echo "=== C. Happy path ==="
start_mock ok

out=$(in_shell "" 'tabs'); rc=$?
echo "$out" | grep -q "Dashboard" && [ "$rc" -eq 0 ]
check_that "tabs lists tabs when everything works" $?

out=$(in_shell "" 'check'); rc=$?
echo "$out" | grep -qi "firefox  *: *connected" && [ "$rc" -eq 0 ]
check_that "check reports connected when it really is" $?

echo
echo "=== D. BRIDGE_URL must stay on this machine ==="
# Assert the refusal MESSAGE, not just a non-zero exit. Both of these would
# "pass" on an unguarded script simply because the request to example.com
# fails on its own - which proves nothing about whether the token was sent.
out=$(in_shell "" 'BRIDGE_URL="http://127.0.0.1:8765@example.com/mcp/call" tabs'); rc=$?
echo "$out" | grep -qi "loopback" && [ "$rc" -ne 0 ]
check_that "userinfo trick (127.0.0.1:8765@example.com) is refused by name" $?

out=$(in_shell "" 'BRIDGE_URL="http://example.com/mcp/call" tabs'); rc=$?
echo "$out" | grep -qi "loopback" && [ "$rc" -ne 0 ]
check_that "non-loopback set AFTER sourcing is refused at call time" $?

echo
echo "=== E. Input validation ==="
start_mock ok

out=$(in_shell "" 'TAB=x; tabs'); rc=$?
echo "$out" | grep -qi "TAB must be a number" && [ "$rc" -ne 0 ]
check_that "non-numeric TAB set after sourcing is refused" $?

out=$(in_shell "" 'shot "b:report.png"'); rc=$?
{ echo "$out" | grep -q '"filename": *"b:report.png"' || [ "$rc" -ne 0 ]; }
check_that "filename starting 'b:' is not coerced to a boolean" $?

out=$(in_shell "CANVAS_HOST=canvas.example.edu" 'api "courses?enrollment_state=active"'); rc=$?
echo "$out" | grep -qi "must start with" && [ "$rc" -ne 0 ]
check_that "api path without leading slash is refused" $?

out=$(in_shell "" 'api "/courses"'); rc=$?
echo "$out" | grep -qi "set CANVAS_HOST" && [ "$rc" -ne 0 ]
check_that "api without CANVAS_HOST set is refused" $?

out=$(in_shell "" 'shot "../../etc/passwd"'); rc=$?
[ "$rc" -ne 0 ]
check_that "path in screenshot filename is refused" $?

echo
echo "=== F. Banner ==="
out=$(env BRIDGE_URL="http://127.0.0.1:$PORT/mcp/call" TOKEN_FILE="$TOKFILE" \
      bash -c "cd '$ROOT'; source scripts/canvas.sh" 2>&1)
echo "$out" | grep -q "check"
check_that "banner mentions the check command" $?

stop_mock
echo
echo "----------------------------------------"
printf ' %d passed, %d failed\n' "$PASS" "$FAIL"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]
