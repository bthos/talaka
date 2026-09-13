#!/bin/bash
# lean-claude.sh — run in your project root

echo "=== CLAUDE.md size ==="
wc -w ~/.claude/CLAUDE.md 2>/dev/null
wc -w .claude/CLAUDE.md 2>/dev/null
echo "Target: combined < 1,200 words"

echo
echo "=== Active hooks ==="
cat ~/.claude/settings.json 2>/dev/null | jq '.hooks // {} | keys'
cat .claude/settings.json 2>/dev/null | jq '.hooks // {} | keys'

echo
echo "=== UserPromptSubmit injections ==="
cat ~/.claude/settings.json 2>/dev/null | jq '.hooks.UserPromptSubmit'
cat .claude/settings.json 2>/dev/null | jq '.hooks.UserPromptSubmit'

echo
echo "=== Output style ==="
for f in ~/.claude/settings.json .claude/settings.json; do
  [ -f "$f" ] || continue
  printf '%s: ' "$f"
  jq -r '.outputStyle // "(unset)"' "$f" 2>/dev/null || echo "(unreadable)"
done
echo 'Target: "Concise". Every agent and skill narrates; this is the one setting that trims all of them.'
echo 'Fix:    talaka/shared/lifecycle/tools/install-output-style.sh --force'

echo
echo "=== Installed plugins ==="
ls ~/.claude/plugins/ 2>/dev/null
echo "Target: 3-5 active. Disable the rest."

echo
echo "=== Installed skills ==="
ls ~/.claude/skills/ 2>/dev/null
echo "Target: 3-5 active matching daily work."

echo
echo "=== Connected MCPs ==="
cat ~/.claude/settings.json 2>/dev/null | jq '.mcpServers // {} | keys'
echo "Target: 3 always-on. Per-session enable rest."

echo
echo "=== Recent session token usage (last 7 days) ==="
find ~/.claude/logs/ -mtime -7 -name "*.log" -exec cat {} + 2>/dev/null \
  | grep -oP 'input_tokens[":]+\K[0-9]+' \
  | awk '{ sum += $1; count++ } END { print "Avg input: " sum/count " tokens"; print "Total prompts: " count }'