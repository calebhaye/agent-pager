#!/usr/bin/env bash
# Claude Code Stop hook: surface any new pages for this session between turns.
#
# Wire it up in .claude/settings.json:
#   { "hooks": { "Stop": [ { "hooks": [ { "type": "command",
#       "command": "AGENT_PAGER_LABEL=my-session /path/to/agent-pager-stop-hook.sh" } ] } ] } }
#
# Each session needs its own label (AGENT_PAGER_LABEL). Register the session
# once at the start of your work:  agent-pager register --label my-session
#
# HONEST LIMITATION: a Stop hook only fires when the agent finishes a turn, so a
# page lands the next time the agent pauses, NOT mid-turn. A session grinding a
# long task will not see it until it stops. There is no reliable mid-turn
# interrupt, so "interrupt me right now" is out of scope by design.

set -euo pipefail
label="${AGENT_PAGER_LABEL:-}"
[ -z "$label" ] && exit 0

bin="${AGENT_PAGER_BIN:-agent-pager}"
command -v "$bin" >/dev/null 2>&1 || exit 0

# keep presence fresh, then check for pages
"$bin" heartbeat --label "$label" >/dev/null 2>&1 || true
pages="$("$bin" inbox --label "$label" --json 2>/dev/null || echo '[]')"

[ "$pages" = "[]" ] || [ -z "$pages" ] && exit 0

# Non-empty: surface to the agent. Hook stdout is shown in the transcript.
echo "agent-pager: you have new pages (act only on ones addressed to you):"
echo "$pages"
