# Canvas via Claude

Let an AI assistant read your own Canvas (Instructure) account — courses,
assignment lists, due dates, grades — by driving the Firefox window you are
already logged into.

No Canvas API token. No password ever passes through the assistant. Nothing
leaves your machine. It clicks around your own browser the same way you would.

**If you are an AI agent, read [`AGENTS.md`](AGENTS.md) instead.** This file is
the human setup; that one is the operating manual.

---

## What this is good for

- "What's due in the next two weeks, across all my courses?"
- "Pull every assignment prompt into a file."
- "Which of these have I not submitted?"
- "Read my grades page and tell me what's actually dragging the average."

## What this is not for

Having an AI write graded work and handing it in. That's between you and your
school's academic integrity policy, and it isn't what this is.

---

## How it works

```
your AI assistant
    |
    |  HTTP POST 127.0.0.1:8765/mcp/call   (local only, token auth)
    v
local server  ->  native messaging host  ->  Firefox extension
                                                  |
                                                  v
                                        your logged-in Canvas tab
```

The extension is the only piece that touches Canvas, and it runs in your own
Firefox profile with your own session cookie.

---

## Setup

**1. Install a browser-control extension + local bridge.**

This was written against `goonspeakstudios-a11y/staros-browser-assistant`, a
hardened fork of [nanogenomic/ClaudeCodeBrowser](https://github.com/nanogenomic/ClaudeCodeBrowser)
(MIT), running as a local HTTP bridge on `127.0.0.1:8765`. That fork is private —
ask for an invite, or build from upstream.

Any bridge exposing `browser_navigate`, `browser_get_page_info`,
`browser_get_elements`, and `browser_screenshot` over local HTTP will work —
only the tool names in `scripts/canvas.sh` would change.

> Install one you have actually read. An extension that can drive a logged-in
> session is as powerful as your password. Avoid unauditable repackages.

**2. Lock down the token file.**

macOS / Linux:

```bash
chmod 600 ~/.staros-browser/api_token
```

Windows — in **PowerShell or cmd**, not Git Bash, where `chmod` looks like it
works and silently doesn't:

```
icacls "%USERPROFILE%\.staros-browser\api_token" /inheritance:r /grant:r "%USERNAME%:R"
```

**3. Open Firefox and sign into Canvas yourself.**

**4. Load the helpers.**

```bash
export CANVAS_HOST="canvas.yourschool.edu"
source scripts/canvas.sh
check
```

| Command | Does |
|---|---|
| `check` | Preflight — server up? Firefox connected? Run this first |
| `tabs` | List open tabs and their ids |
| `go <url>` | Navigate the target tab, report where it landed |
| `api <path>` | Hit a Canvas REST endpoint in the tab |
| `shot [file]` | Full-page screenshot |

Default tab is `1`. Change with `export TAB=3` before sourcing.

---

## The login step is yours

Type your username and password into the Firefox window. Do not paste them into
the assistant, and do not ask it to type them.

Worth knowing: on SAML SSO schools the identity provider often still has a live
session after the *Canvas* session expires. Submitting the login form with both
fields empty is then enough — the IdP already recognises the browser and
forwards a fresh token.

That is **not** a way around logging in. It works only because you were already
authenticated in your own browser, and does nothing on a machine that has never
signed in. If it fails, type your password. That's the normal path.

---

## Tests

```bash
bash tests/run_tests.sh
```

No Firefox or real bridge needed — `tests/mock_bridge.py` stands in. It exists
because of one detail that's easy to get wrong:

**A closed browser is not silence.** The bridge waits 30 seconds and returns
HTTP 200 with well-formed JSON:

```json
{"success": false, "error": "Command getTabs timed out waiting for browser response after 30s"}
```

So "did I get JSON back?" is not a success check. Every real failure — dead
browser, stale token, unknown tool, malformed body — arrives as parseable JSON.
A client that doesn't read the body reports all of them as fine. The first
version of this script did exactly that, and its `check` reported
`firefox: connected` with Firefox closed.

---

## Safety notes

- Keep JS-execution tools (`browser_execute_script`, `browser_eval_chain`,
  `browser_wait_and_act`) **disabled** unless you need them, and always disabled
  while a banking or payroll tab is open.
- The bridge binds `127.0.0.1` only. Never `0.0.0.0`. `scripts/canvas.sh`
  refuses to run against any non-loopback address, since that's what decides
  where your token gets sent.
- Your assistant's transcript may be logged. Keep credentials out of it — that's
  the point of doing the login yourself.
- This drives a real, logged-in session. Anything the assistant does, your
  account did.

---

## License

MIT. Built on [nanogenomic/ClaudeCodeBrowser](https://github.com/nanogenomic/ClaudeCodeBrowser).
