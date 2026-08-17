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
   against `goonspeakstudios-a11y/staros-browser-assistant` — a hardened fork of
   [nanogenomic/ClaudeCodeBrowser](https://github.com/nanogenomic/ClaudeCodeBrowser)
   (MIT). That fork is private; ask for an invite if you don't have one, or
   build from the upstream project.

   Any bridge that exposes `browser_navigate`, `browser_get_page_info`,
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
down so only you can read it.

On macOS or Linux, in your shell:

```bash
chmod 600 ~/.staros-browser/api_token
```

On Windows, in **PowerShell or cmd** — not in Git Bash, where `chmod` looks like
it works and does not:

```
icacls "%USERPROFILE%\.staros-browser\api_token" /inheritance:r /grant:r "%USERNAME%:R"
```

Then load the helpers:

```bash
export CANVAS_HOST="canvas.yourschool.edu"
source scripts/canvas.sh
```

That gives you five commands:

| Command | Does |
|---|---|
| `check` | Preflight — is the server up, is Firefox connected, which python |
| `tabs` | List open tabs and their ids |
| `go <url>` | Navigate the target tab, report where it landed |
| `api <path>` | Hit a Canvas REST endpoint in the tab |
| `shot [file]` | Full-page screenshot |

**Run `check` first.** It separates the two failure modes that look identical
from the outside — server down vs. Firefox closed.

The script deliberately never puts your token on a command line, in an
environment variable, or in a temp file; it pipes it into curl on stdin at call
time. It also refuses to run if `BRIDGE_URL` points anywhere but your own
machine, since that address is what decides where the token gets sent.

---

## The walkthrough

### 0. Firefox has to be open

The bridge authenticates happily with no browser running, then every page call
times out 30 seconds later. It looks like an auth problem and is not. Preflight:

```bash
check
tabs
```

`tabs` prints the id of every open tab. Note the one you want to drive —
everything below assumes tab `1`. Change it with `export TAB=3` before sourcing.

### 1. Go to Canvas

```bash
go "https://$CANVAS_HOST"
```

It prints the URL and title it landed on, which is how you tell step 2 apart
from being already signed in.

### 2. The login step — you do this part, not Claude

If the URL lands on an SSO gateway or a `loginuserpass.php` form, you are not
signed in. **Type your username and password into the Firefox window yourself.**
Do not paste credentials into Claude, and do not ask it to type them.

One thing worth knowing: schools using SAML SSO often still have a live session
at the identity provider even after the *Canvas* session expires. Submitting the
login form with both fields empty is then enough — the identity provider already
recognises the browser and forwards a fresh token. Worth trying before you reach
for the password:

```bash
bcall browser_click "$(_json tab_id i "$TAB" selector s 'button[type=submit]')"
sleep 7
go "https://$CANVAS_HOST"
```

If it lands on the dashboard, you are in and no credentials moved anywhere.

To be clear about what that is: it is **not** a way around logging in. It works
only because *you* were already authenticated in *your own* browser, and it does
nothing at all on a machine that has never signed in. If it fails, type your
password into the Firefox window — that is the normal path, not a fallback.

### 3. When DOM reads come back empty — the important trick

Canvas ships a strict Content-Security-Policy. The extension's content script
frequently cannot attach, so `browser_get_elements` returns `count: 0` on a page
that is plainly full of links. It may also latch onto an SSO iframe instead of
the top frame.

Do not fight it. **Use Canvas's own REST API in the browser tab.** You are
already authenticated by cookie, so every endpoint just renders as JSON:

```bash
api '/courses?enrollment_state=active'                       # your active courses
api '/courses/COURSE_ID/assignments?per_page=50'             # assignments in one course
api '/courses/COURSE_ID/assignments/ASSIGNMENT_ID'           # one assignment, full text
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
shot week01.png
```

`shot` strips the base64 image field out of the response before printing it. Do
the same if you roll your own, or you will flood the terminal with a megabyte of
noise. It takes a filename only, not a path.

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
| "Python was not found", exit 49 | On Windows, `python3` resolves to the Microsoft Store stub — it exists on PATH and does nothing | `scripts/canvas.sh` tests each candidate by running it. If you rolled your own, do the same, or set `PY` to a full path |
| `chmod 600` appears to work but the file stays readable | Git Bash on Windows emulates POSIX permissions and silently drops them on `/tmp` | Use `icacls`. Do not trust a "private" temp file created from Git Bash |

---

## Tests

```bash
bash tests/run_tests.sh
```

No Firefox and no real bridge needed — `tests/mock_bridge.py` stands in for the
server. It exists because of one detail that is easy to get wrong:

**A closed browser is not silence.** The bridge waits 30 seconds and then
returns HTTP 200 with well-formed JSON:

```json
{"success": false, "error": "Command getTabs timed out waiting for browser response after 30s"}
```

So "did I get JSON back?" is not a success check. Every real failure — dead
browser, stale token, unknown tool, malformed body — comes back as parseable
JSON at 200 or 403. A client that does not read the body reports all of them as
fine, prints an empty result, and exits 0. The first version of this script did
exactly that, and its `check` command cheerfully reported `firefox: connected`
with Firefox closed.

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
