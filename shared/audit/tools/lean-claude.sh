#!/bin/bash
# lean-claude.sh — run in your project root

echo "=== CLAUDE.md size ==="
wc -w ~/.claude/CLAUDE.md 2>/dev/null
wc -w .claude/CLAUDE.md 2>/dev/null
echo "Target: combined < 1,200 words"

echo
# The kit writes its own settings (memory hook, outputStyle) to the per-developer
# .claude/settings.local.json, so every check reads it too.
SETTINGS_FILES=( ~/.claude/settings.json .claude/settings.json .claude/settings.local.json )

echo "=== Active hooks ==="
for f in "${SETTINGS_FILES[@]}"; do
  [ -f "$f" ] && { printf '%s: ' "$f"; jq -c '.hooks // {} | keys' "$f" 2>/dev/null || echo "(unreadable)"; }
done

echo
echo "=== UserPromptSubmit injections ==="
for f in "${SETTINGS_FILES[@]}"; do
  [ -f "$f" ] && { printf '%s: ' "$f"; jq -c '.hooks.UserPromptSubmit' "$f" 2>/dev/null || echo "(unreadable)"; }
done

echo
echo "=== Output style ==="
for f in "${SETTINGS_FILES[@]}"; do
  [ -f "$f" ] || continue
  printf '%s: ' "$f"
  jq -r '.outputStyle // "(unset)"' "$f" 2>/dev/null || echo "(unreadable)"
done
echo 'Target: "Concise". Every agent and skill narrates; this is the one setting that trims all of them.'
echo 'Fix:    bash talaka/shared/lifecycle/tools/install-output-style.sh --force'

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