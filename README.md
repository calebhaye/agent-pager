# agent-pager

A dead-simple way to reach your local AI agents when you're not at the machine.
Each machine has one GitHub issue as its **pager inbox**. You comment on it from
your phone; the agents on that machine see it and act, and can reply back on the
thread (and, eventually, text you). No server, no sockets: `gh`, one issue, and a
small poll loop.

Sibling to [agent-relay](https://github.com/calebhaye/agent-relay). agent-relay
is agent-to-agent over a shared issue; agent-pager is you-to-agents over a
per-machine issue. Same idea (a GitHub issue as a mailbox + polling), so if you
know one you know the other.

## The one rule that shapes everything

If you run many sessions on a machine (dozens), you do **not** want each of them
polling GitHub. So: **one poller per machine**, and every session reads a common
local spot the poller writes to. GitHub gets hit once per machine; sessions only
ever touch a local file.

```
your phone ─┐
            ▼
   GitHub issue (one per machine, private repo)
            ▲  ▼
        the poller  (one tiny loop per machine)
            ▼  ▲
   ~/.agent-pager/inbox   (a local file or sqlite; the common spot)
            ▲  ▲  ▲
      session  session  session ...   (read locally, cheap)
```

## The poller (one per machine)

A small loop that reads the machine's issue, appends new comments to the local
inbox, and drains a local outbox back to the issue. Run it however you like
(`launchd`/`systemd`/`tmux`/`while true`). It is the only thing that talks to the
network.

```bash
REPO=calebhaye/agent-pager     # or a private repo you own
ISSUE=1                         # this machine's pager issue
STORE=~/.agent-pager
mkdir -p "$STORE"; : > "$STORE/seen"

while true; do
  # inbound: new comments -> local inbox (id<TAB>login<TAB>body)
  gh api "repos/$REPO/issues/$ISSUE/comments" \
    --jq '.[] | "\(.id)\t\(.user.login)\t\(.body | gsub("[\n\r]+";" "))"' \
  | while IFS=$'\t' read -r id login body; do
      grep -q "^$id$" "$STORE/seen" && continue
      echo "$id" >> "$STORE/seen"
      # SECURITY: only accept pages from you (and your agent bot). See below.
      case "$login" in calebhaye|your-agent-bot) : ;; *) continue ;; esac
      printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$login" "$body" >> "$STORE/inbox"
    done

  # outbound: drain outbox -> comments (agents append lines here)
  if [ -s "$STORE/outbox" ]; then
    while IFS= read -r line; do
      gh issue comment "$ISSUE" --repo "$REPO" --body "$line"
    done < "$STORE/outbox"
    : > "$STORE/outbox"
  fi

  sleep 30
done
```

That's the whole moving part. Swap the flat files for a tiny sqlite db if you
want per-session cursors and statuses; the shape is the same (one writer, many
readers).

## What a session does

A session never touches GitHub. It reads the local inbox and, when it has
something to say, appends a line to the local outbox.

- **Check for pages** (cheap, local): read new lines from `~/.agent-pager/inbox`.
  Do this between turns. In Claude Code, a `Stop` hook that tails the inbox is the
  natural trigger; a long-idle session can also just re-check on a timer.
- **Reply / ping the human**: append one line to `~/.agent-pager/outbox`. The
  poller posts it as a comment. Start it with `@you` to notify your phone.

## Addressing (so 50 sessions don't all react)

Give each session a short label (e.g. its repo or role). Then:

- `@api-backend: rerun the failing spec` — only the session with that label acts.
- `@all: pull main` — every session acts.
- No `@label` — informational; sessions see it, none auto-acts.

Default to "act only if addressed." A broadcast that makes every session do
something is how you get chaos.

## Security (not optional)

A comment that drives local agents is remote control of your machine. So:

- **Private repo.**
- The poller **only accepts comments from an allowlist** (your GitHub login, and
  your agent bot if you use one). Everything else is ignored. See the `case` in
  the poller above.

## Optional: a GitHub agent user

Not required, but nice: a dedicated GitHub account (a "machine user", which
GitHub permits) for the agent side. It gives clean attribution (you @-mention the
agent, the agent @-mentions you, as distinct identities), a natural allowlist
entry, and it works in headless/cron where your interactive `gh` auth might not.
Make it a config value (`PAGER_GH_TOKEN` / `PAGER_GH_LOGIN`), defaulting to your
own `gh` auth, so it's never a prerequisite to get started.

## Getting started

1. Pick a private repo. Open one issue per machine, titled e.g.
   `pager: studio` or `pager: laptop`.
2. Run the poller on each machine (point it at that machine's issue).
3. Tell each session its label and that its inbox is `~/.agent-pager/inbox` and
   its outbox is `~/.agent-pager/outbox`.
4. From anywhere, comment on the machine's issue. `@label` to target one session,
   `@all` to hit them all.

## Deliberately small

Like agent-relay, this is meant to stay a README and a poll loop. Resist turning
the poller into a daemon-with-a-control-plane. The value is that it's a few lines
you can read in one sitting and trust.
