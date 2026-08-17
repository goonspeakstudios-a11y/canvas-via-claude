# Canvas via Claude

Let Claude Code read your own Canvas (Instructure) account — courses, assignment
lists, due dates, grades — by driving the Firefox window you are already logged
into.

No Canvas API token. No password ever passes through Claude. Nothing is stored
on a server. Claude clicks around your own browser the same way you would.

Tested against a Stanford Canvas install (SAML SSO). The method is generic —
the same steps work on any school running Canvas.

---

## What this is good for

- "What's due in the next two weeks, across all my courses?"
- "Pull the full text of every assignment prompt into a file."
- "Which of these have I not submitted yet?"
- "Read my grades page and tell me what's actually dragging the average."

## What this is not for

Do not use this to have Claude write graded work and hand it back for
submission. That is between you and your school's academic integrity policy,
and it is not what this guide is for.

---

## How it works

```
Claude Code
    |
    |  HTTP POST 127.0.0.1:8765/mcp/call   (local only, token auth)
    v
local server  ->  native messaging host  ->  Firefox extension
                                                  |
                                                  v
                                        your logged-in Canvas tab
```

The extension is the only piece that touches Canvas, and it runs inside your
own Firefox profile with your own session cookie. Claude never sees a password.

---

## Requirements

1. **Firefox**, with a profile you normally use for Canvas.
2. **A browser-control extension + local MCP server.** This guide was written
   against a hardened fork of [nanogenomic/ClaudeCodeBrowser](https://github.com/nanogenomic/ClaudeCodeBrowser)
   (MIT). Any bridge that exposes `browser_navigate`, `browser_get_page_info`,
   `browser_get_elements`, and `browser_screenshot` over local HTTP will work —
   only the tool names below would change.
3. **Python 3** (used here just to pretty-print JSON responses).
4. `curl`.

> Heads up on the extension: install one you have actually read. Browser
> extensions that can drive a logged-in session are as powerful as your
> password. Avoid unauditable repackages that dump OAuth tokens to disk.

---

## Setup

The local server writes an API token to `~/.staros-browser/api_token`. Lock it
down so only you can read it:

```bash
# Windows
icacls "%USERPROFILE%\.staros-browser\api_token" /inheritance:r /grant:r "%USERNAME%:R"

# macOS / Linux
chmod 600 ~/.staros-browser/api_token
```

Then set a shell helper so every call is one line:

```bash
export CANVAS_HOST="canvas.yourschool.edu"
TOK=$(cat "$HOME/.staros-browser/api_token" | tr -d '\r\n')

bcall() {  # bcall <tool_name> <json_args>
  curl -s -m 60 -X POST http://127.0.0.1:8765/mcp/call \
    -H "Content-Type: application/json" \
    -H "X-API-Key: $TOK" \
    -d "{\"name\":\"$1\",\"arguments\":$2}"
}
```

There is a ready-made version in [`scripts/canvas.sh`](scripts/canvas.sh).

---

## The walkthrough

### 0. Firefox has to be open

The bridge will authenticate happily with no browser running, then every page
call times out after 30s. Check first:

```bash
bcall browser_get_tabs '{}' | python -c "
import sys,json
for t in json.load(sys.stdin).get('tabs',[]):
    print(t['id'],'|',t.get('title','')[:60],'|',t.get('url','')[:90])
"
```

Note the tab id you want to drive. Everything below assumes `tab_id: 1`.

### 1. Go to Canvas

```bash
bcall browser_navigate "{\"url\":\"https://$CANVAS_HOST\",\"tab_id\":1}"
sleep 7
bcall browser_get_page_info '{"tab_id":1}' | python -c "
import sys,json; d=json.load(sys.stdin)
print('URL  :', d.get('url')); print('TITLE:', d.get('title'))
"
```

### 2. The login step — you do this part, not Claude

If the URL lands on an SSO gateway or a `loginuserpass.php` form, you are not
signed in. **Type your username and password into the Firefox window yourself.**
Do not paste credentials into Claude, and do not ask it to type them.

One thing worth knowing: schools using SAML SSO often still have a live session
at the identity provider even after the Canvas session expires. In that case
submitting the login form with both fields empty is enough — the IdP recognises
you and forwards a fresh token. Worth trying before you reach for the password:

```bash
bcall browser_click '{"tab_id":1,"selector":"button[type=submit]"}'
sleep 7
bcall browser_get_page_info '{"tab_id":1}' | python -c "
import sys,json; d=json.load(sys.stdin); print(d.get('url')); print(d.get('title'))
"
```

If it lands on the dashboard, you are in and no credentials moved anywhere.

### 3. When DOM reads come back empty — the important trick

Canvas ships a strict Content-Security-Policy. The extension's content script
frequently cannot attach, so `browser_get_elements` returns `count: 0` on a page
that is plainly full of links. It may also latch onto an SSO iframe instead of
the top frame.

Do not fight it. **Use Canvas's own REST API in the browser tab.** You are
already authenticated by cookie, so every endpoint just renders as JSON:

```bash
# your active courses
bcall browser_navigate "{\"url\":\"https://$CANVAS_HOST/api/v1/courses?enrollment_state=active\",\"tab_id\":1}"

# assignments for one course
bcall browser_navigate "{\"url\":\"https://$CANVAS_HOST/api/v1/courses/COURSE_ID/assignments?per_page=50\",\"tab_id\":1}"

# a single assignment, full prompt text
bcall browser_navigate "{\"url\":\"https://$CANVAS_HOST/api/v1/courses/COURSE_ID/assignments/ASSIGNMENT_ID\",\"tab_id\":1}"
```

Useful endpoints:

| What you want | Endpoint |
|---|---|
| Active courses | `/api/v1/courses?enrollment_state=active` |
| Assignments | `/api/v1/courses/:id/assignments?per_page=50` |
| One assignment | `/api/v1/courses/:id/assignments/:aid` |
| Your submissions | `/api/v1/courses/:id/students/submissions?student_ids[]=self` |
| Upcoming across all courses | `/api/v1/users/self/upcoming_events` |
| Announcements | `/api/v1/announcements?context_codes[]=course_:id` |

### 4. Reading the result

Screenshots work even when DOM reads do not, so they are the reliable fallback:

```bash
bcall browser_screenshot '{"tab_id":1,"save_to_file":true,"filename":"canvas.png","full_page":true}' \
  | python -c "
import sys,json; d=json.load(sys.stdin)
for k in ('image','data','base64'): d.pop(k, None)
print(json.dumps(d)[:400])
"
```

Strip the base64 image field before printing or you will flood your terminal
with a megabyte of noise.

For long assignment text, the rendered HTML page is easier to read than the raw
JSON blob — navigate to `/courses/:id/assignments/:aid` and screenshot it
`full_page`.

---

## Gotchas that cost real time

| Symptom | Cause | Fix |
|---|---|---|
| Every page call times out after 30s | Firefox is not running | Open Firefox. The server authenticates fine with no browser attached, which makes this look like an auth bug |
| `browsers_connected: 0` on `/health` | Counts WebSocket clients only; the extension uses HTTP long-poll | Ignore it. 0 is normal while fully connected |
| "Command queued" and nothing happens | Wrong endpoint | Use `/mcp/call` (synchronous), not `/browser/command` (queues only) |
| 401 on every call | Wrong header name | It is `X-API-Key`, not `X-API-Token` |
| "Invalid arguments" | Wrong case | Args are snake_case: `tab_id`, not `tabId` |
| "Receiving end does not exist" | Tab was loaded before the extension | Reload the tab — the content script injects at `document_end` |
| `count: 0` on a page full of links | Canvas CSP blocking the content script | Use the REST API endpoints above, or screenshot |
| Reads return SSO iframe content | Content script attached to the wrong frame | Re-navigate to the top-level URL, then read |

---

## Safety notes

- Keep any JS-execution tools (`browser_execute_script`, `browser_eval_chain`,
  `browser_wait_and_act`) **disabled** unless you specifically need them, and
  always disabled while a banking or payroll tab is open. A good bridge
  fail-closes these behind two separate switches — a server config flag and an
  extension toggle — so a compromise of one does not turn them on.
- The server binds `127.0.0.1` only. Never bind `0.0.0.0`.
- Your Claude Code transcript may be logged. Keep credentials out of the
  conversation entirely — the point of step 2 is that they never enter it.
- This drives a real, logged-in session. Anything Claude does, your account did.

---

## License

MIT. Built on top of [nanogenomic/ClaudeCodeBrowser](https://github.com/nanogenomic/ClaudeCodeBrowser).
