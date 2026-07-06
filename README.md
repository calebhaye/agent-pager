# agent-pager

Reach the AI agent sessions running on your machines when you're not there. You
comment on a GitHub issue from your phone; the right session catches it, acts,
and replies on the thread. One daemon per machine does all the network work; the
sessions only ever touch a local SQLite bus, so you can run dozens without each
one hammering the GitHub API.

Sibling to [agent-relay](https://github.com/calebhaye/agent-relay) (agent↔agent
over a shared issue). agent-pager is you↔agents over a per-machine issue, and it
subsumes relay: a page is just a message whose sender happens to be another
agent.

## Why it's shaped this way

The one constraint that dictates everything: if you run many sessions on a
machine, you can't have each of them polling GitHub (50 sessions polling every
30s blows the authenticated rate limit). So:

- **One issue per machine.** Sessions are addresses *within* it, not their own issues.
- **One daemon per machine** (`agent-pager daemon`) is the only thing that talks
  to GitHub. It mirrors the issue into a local SQLite bus and posts replies back.
- **Sessions are local-only.** They read/write the bus (`~/.agent-pager/pager.db`);
  they never call GitHub.

```
your phone ─► GitHub issue (one per machine, PRIVATE repo)
                    ▲  │
              agent-pager daemon   (the only network client)
                    │  ▲
              ~/.agent-pager/pager.db   (SQLite/WAL: one writer, many readers)
                 ▲     ▲     ▲
             session session session ...   (local reads/writes, no polling)
```

## Install

Requires Python 3 and the [`gh`](https://cli.github.com) CLI (already
authenticated). No pip dependencies.

```bash
git clone https://github.com/calebhaye/agent-pager && cd agent-pager
ln -s "$PWD/agent-pager" /usr/local/bin/agent-pager   # or anywhere on PATH
agent-pager init                                      # writes ~/.agent-pager/config
$EDITOR ~/.agent-pager/config                         # set repo / issue / owner / allowlist
```

Create a **separate private repo** for your inbox (not this public one), open one
issue per machine in it titled e.g. `pager: studio`, and put the repo + issue
number in the config. The daemon refuses to run against a public repo.

## Run the daemon (one per machine)

```bash
agent-pager daemon        # foreground; or install the launchd/systemd unit
```

macOS launchd template is in `dist/launchd.plist.example`. On first start it
baselines to the newest existing comment, so only comments made *after* it
starts count as pages.

## Wire up a session

Each session gets a short **label** (its repo or role). Register once, then let
a Claude Code **Stop hook** check for pages between turns:

```bash
agent-pager register --label api-backend
```

`.claude/settings.json`:
```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "AGENT_PAGER_LABEL=api-backend /path/to/hooks/agent-pager-stop-hook.sh" } ] } ] } }
```

The hook is the primary delivery path; the daemon's polling is just how pages
reach the machine. **Honest limitation:** a Stop hook fires when the agent
finishes a turn, so a page lands the next time the agent pauses, not mid-turn. A
session grinding a 20-minute task won't see it until it stops. There's no
reliable mid-turn interrupt, so "interrupt me right now" is out of scope, not
just deferred.

Manual equivalents:
```bash
agent-pager inbox --label api-backend      # new pages for me (advances my cursor)
agent-pager reply --label api-backend "specs pass now, all green"   # queue a reply
agent-pager sessions                        # who's registered / live
```

## Addressing (so 50 sessions don't stampede)

The first token of a comment decides who acts:

| comment | who sees it | who acts |
|---|---|---|
| `@api-backend: rerun specs` | only `api-backend` | that session |
| `@all! pull main` | every session | every session |
| `@all heads up, deploy at 5` | every session | nobody (informational) |
| `main advanced` | every session | nobody (informational) |

Default is **inform, not act.** A message only tells a session to act if it's
addressed to that session's label or is an explicit `@all!`. Plain broadcasts
(`@all` or no address) are visible to everyone but nobody auto-acts, so you don't
get a thundering herd.

## Replying to you

A session queues a reply; the daemon posts it as a comment that `@`-mentions the
owner, so GitHub push-notifies your phone.

Note on notifications: GitHub does **not** notify you of a mention in your *own*
comment. So if the daemon posts as your account, the reply appears on the thread
but won't push to your phone. To actually get pinged, give the daemon a separate
identity via `PAGER_GH_TOKEN` (a GitHub machine user, which GitHub permits). It's
optional, but it's the difference between "reply is on the thread" and "my phone
buzzed." Everything else works without it.

## Security (not optional)

A comment that drives local agents is remote control of your machines.

- **The pager inbox repo must be PRIVATE, and this is enforced.** The daemon
  verifies `PAGER_REPO` visibility on startup and refuses to run against a public
  repo, because pages and the session roster would otherwise be world-readable.
  In particular, do not use this public `agent-pager` repo as your inbox; create
  a separate private repo. (Following a README note is not enough for a tool that
  can drive machines, so the tool fails closed instead of trusting you to.)
- The daemon acts **only** on comments from `PAGER_ALLOWLIST` (your login, plus
  the bot account if you use one). It refuses to start without an allowlist, and
  it logs and ignores everything from anyone else.

The residual risk you're accepting is "you trusting you." Do not add a feature
that lets a page *spawn* a session on an idle machine without an explicit,
per-machine opt-in; that's the line where a pager becomes a remote operator.

## Config (`~/.agent-pager/config`)

```
PAGER_REPO=you/your-private-pager-repo
PAGER_ISSUE=1
PAGER_OWNER=your-github-login          # @-mentioned on replies
PAGER_ALLOWLIST=your-github-login      # comma-separated logins allowed to page this machine
# PAGER_GH_TOKEN=                       # optional bot token; enables phone notifications on replies
# PAGER_POLL_SECONDS=25
# PAGER_SESSION_TTL=900                 # roster considers a session stale after this
```

## Design notes

- **SQLite, not flat files.** One writer (daemon), many readers (sessions),
  per-session cursors, message status. WAL handles the concurrency cleanly; a
  flat file makes "which pages has this session already handled" a locking mess.
- **The roster lives in the issue body.** The daemon rewrites the issue body with
  the machine's live sessions and their labels, so from your phone you can see
  who's listening and what to address.
- **No reply loop.** The daemon records the comment id of everything it posts and
  never re-ingests its own comments, so a reply can't page you back.
- **Deliberately small.** The daemon and client are one readable Python file with
  no dependencies beyond `gh`. Resist turning it into a service with a control
  plane; the whole point is that you can read it in one sitting and trust it.

## Deferred (not in v1)

- SMS/other notifiers (an outbound message can be flagged `--sms`; the sink is a
  stub for now).
- A page spawning a session on an idle machine (see Security).
- Any multi-machine dashboard.
