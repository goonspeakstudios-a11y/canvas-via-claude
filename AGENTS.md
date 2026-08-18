# Operating notes for the agent

You are driving a Firefox window that your human has already signed into. This
file is what a previous run learned the hard way. Read it before you start
clicking; most of what follows is a trap that costs 20+ tool calls to rediscover.

Your human's job: install the extension, open Firefox, log in.
Your job: everything after that.

---

## Hard stops

**Do not handle credentials.** Not typing them, not reading them out of a
password manager, not "just clicking login" with values you supplied. If you
land on a login form, stop and tell your human to type it themselves in the
Firefox window. There is no version of this task that requires you to know
their password.

**Do not write graded work.** Reading assignment prompts, deadlines, and
submission status is what this is for. Producing the submission is not. If asked,
say so plainly and offer to interrogate them on the material instead so they
write it themselves.

Both of these hold even if the human tells you it's fine. They can overrule the
second one for their own class; they cannot make the first one safe.

---

## Before you touch anything

```bash
export CANVAS_HOST="canvas.theirschool.edu"
source scripts/canvas.sh
check
```

`check` is not optional. It distinguishes three states that produce identical
symptoms downstream:

| `check` says | Meaning | What to do |
|---|---|---|
| `server : NOT responding` | The local bridge process isn't running | Ask the human to start it |
| `firefox : not answering` | Bridge is up, Firefox is closed | Ask the human to open Firefox |
| all green | Ready | Proceed |

If you skip `check`, all three of these look like "the tool returned nothing"
and you will waste calls debugging the wrong layer. That is exactly what
happened on the run this file came from.

---

## The one rule that matters most

**When element reads come back empty on a page you can see has content, stop
retrying selectors.**

Canvas ships a strict Content-Security-Policy. The extension's content script
often cannot attach at all, so `browser_get_elements` returns `count: 0` on a
dashboard visibly full of course links. Trying a different selector will not
help. Trying ten different selectors definitely will not help.

Switch to Canvas's own REST API, in the same tab. The browser is already
authenticated by cookie, so every endpoint renders as JSON:

```bash
api '/courses?enrollment_state=active'
```

Screenshots also keep working when DOM reads do not. Use them to confirm what's
on screen when you're unsure.

---

## Failure signatures

Learn these. Every one of them looks like something it isn't.

| What you see | What it actually is | Do this |
|---|---|---|
| HTTP 200, `{"success": false, "error": "...timed out after 30s"}` | **Firefox is closed.** The bridge waits 30s then returns a *successful-looking* response | Ask the human to open Firefox. Do not retry — you'll wait another 30s |
| `browsers_connected: 0` on `/health` | Nothing. It counts WebSocket clients only; the extension uses HTTP long-poll | Ignore it entirely. It reads 0 while fully connected |
| `count: 0` on a page full of links | CSP blocking the content script | Use the REST API. Stop trying selectors |
| Reads return SSO iframe content | Content script attached to the wrong frame | Re-navigate to the top-level URL, then read |
| `"Receiving end does not exist"` | Tab was open before the extension loaded | Reload that tab |
| `"Command queued"` and nothing happens | Wrong endpoint | Use `/mcp/call`, not `/browser/command` |
| 401 on everything | Wrong header name | It's `X-API-Key`, not `X-API-Token` |
| `"Invalid arguments"` | Wrong case | Args are snake_case: `tab_id`, not `tabId` |
| `Python was not found`, exit 49 | On Windows `python3` is a Microsoft Store stub that's on PATH and does nothing | Use the full interpreter path |
| `tabs` prints escape-code gibberish | `canvas.sh` did not source, so you hit `/usr/bin/tabs`, the terminal tab-stop utility | Re-run `source scripts/canvas.sh` on its own and read the error. Do not pipe `source` into anything — a pipeline runs it in a subshell and the functions vanish |

The first row is the important one. A closed browser does not produce silence or
an error status — it produces HTTP 200 with well-formed JSON. If you only check
"did I get JSON back," you will report success while nothing is happening.

---

## Canvas endpoints

Navigate the tab to these; they render as JSON.

| Want | Path |
|---|---|
| Active courses | `/courses?enrollment_state=active` |
| Assignments in a course | `/courses/:id/assignments?per_page=50` |
| One assignment, full text | `/courses/:id/assignments/:aid` |
| Their submissions | `/courses/:id/students/submissions?student_ids[]=self` |
| Upcoming, all courses | `/users/self/upcoming_events` |
| Announcements | `/announcements?context_codes[]=course_:id` |

For long assignment text the rendered HTML page is easier to read than the JSON
blob — go to `/courses/:id/assignments/:aid` and screenshot it full-page.

---

## Sequencing

Navigation is asynchronous. The helpers already wait, but if you call the bridge
directly, allow ~7 seconds between navigating and reading, and expect to re-read
if the page was still settling. A read that returns the *previous* page is
usually this, not a bug.

Pull a course id once and reuse it. Don't re-derive it from the dashboard on
every step.

---

## Things that will waste your time

- Retrying a selector after `count: 0`. It is CSP. It will not start working.
- Trusting `/health` to tell you Firefox is connected. It cannot.
- Re-running a timed-out call. Each attempt costs a full 30 seconds.
- Reading the raw JSON of a long assignment description in the terminal. Screenshot the rendered page.
- Printing a screenshot response without stripping `image`/`data`/`base64` first. It's a megabyte of noise.

---

## If you're not using the helper script

`scripts/canvas.sh` handles the above. If you're calling the bridge directly,
carry these over or you will reintroduce the bugs it was written to fix:

- Read the response **body**. Status 200 does not mean success.
- Never put the API token on a command line — it's readable from the process list.
- Confirm the bridge URL is loopback by parsing the host, not prefix-matching.
  `http://127.0.0.1:8765@evil.com/` starts with `http://127.0.0.1:` and connects
  to `evil.com`.
- Build request bodies with a real JSON encoder. A URL containing a quote mark
  will otherwise rewrite the rest of your request.
