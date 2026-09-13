#!/usr/bin/env bash
# collect-usage.sh reads real token counts out of a Claude Code transcript.
# The whole point is that it refuses to produce a number it did not measure, so
# most of these tests are about the refusal paths.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

TOOL="$KIT_ROOT/templates/autoresearch/tools/collect-usage.sh"
PRICING="$KIT_ROOT/templates/autoresearch/tools/pricing.json"

_need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  fail "jq not available — collect-usage cannot be exercised"
  return 1
}

# Build a fake ~/.claude/projects tree holding one transcript for $cwd.
# Returns the CLAUDE_CONFIG_DIR to export.
_fake_transcript() {
  local root="$1" cwd="$2" ts="$3" model="${4:-claude-opus-5}"
  local dir="$root/projects/fake-project"
  mkdir -p "$dir"
  # Two assistant messages with usage, one user message without.
  {
    printf '{"type":"user","cwd":"%s","timestamp":"%s"}\n' "$cwd" "$ts"
    printf '{"type":"assistant","cwd":"%s","isSidechain":false,"timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":500,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":500}}}}\n' \
      "$cwd" "$ts" "$model"
    printf '{"type":"assistant","cwd":"%s","isSidechain":true,"timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":10,"cache_read_input_tokens":20,"output_tokens":30,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}\n' \
      "$cwd" "$ts" "$model"
  } > "$dir/session-abc.jsonl"
  printf '%s' "$root"
}

test_sums_measured_tokens_from_the_transcript() {
  _need_jq || return
  local tmp; tmp=$(make_tmp_project); cd "$tmp" || return
  local cfg; cfg=$(_fake_transcript "$tmp/fakehome" "$(pwd)" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)")

  local out
  out=$(CLAUDE_CONFIG_DIR="$cfg" "$TOOL" --pricing "$PRICING" --json 2>/dev/null)
  assert_eq "0" "$?" "exits 0 when it measured something"

  # 100+1000+200+500 (main) + 10+20+30 (sidechain) = 1860
  assert_eq "1860" "$(printf '%s' "$out" | jq -r '.tokens_total')" "sums every billed token kind"
  assert_eq "2"    "$(printf '%s' "$out" | jq -r '.messages')"     "counts only messages carrying usage"
}

test_sidechain_only_counts_subagent_turns() {
  _need_jq || return
  local tmp; tmp=$(make_tmp_project); cd "$tmp" || return
  local cfg; cfg=$(_fake_transcript "$tmp/fakehome" "$(pwd)" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)")

  local out
  out=$(CLAUDE_CONFIG_DIR="$cfg" "$TOOL" --pricing "$PRICING" --sidechain-only --json 2>/dev/null)
  assert_eq "60" "$(printf '%s' "$out" | jq -r '.tokens_total')" "only the isSidechain row"
}

test_prices_one_hour_cache_writes_at_the_one_hour_rate() {
  # 1h writes cost 2x input, 5m writes 1.25x. Folding them together understates
  # a Claude Code session, which writes almost entirely 1h entries.
  _need_jq || return
  local tmp; tmp=$(make_tmp_project); cd "$tmp" || return
  local cfg; cfg=$(_fake_transcript "$tmp/fakehome" "$(pwd)" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)")

  local out cost
  out=$(CLAUDE_CONFIG_DIR="$cfg" "$TOOL" --pricing "$PRICING" --json 2>/dev/null)
  cost=$(printf '%s' "$out" | jq -r '.cost_usd')

  # Opus 5: input $5, output $25, 1h write $10, cache read $0.50 per MTok.
  #   main:      100*5 + 200*25 + 500*10 + 1000*0.50  = 500+5000+5000+500  = 11000
  #   sidechain: 10*5  + 30*25  + 0       + 20*0.50   = 50+750+10          = 810
  #   total 11810 / 1e6 = 0.01181
  local want="0.01181"
  local same; same=$(awk -v a="$cost" -v b="$want" 'BEGIN{print (a-b < 0.0000001 && b-a < 0.0000001) ? "yes":"no"}')
  assert_eq "yes" "$same" "cost is $want (got $cost) — 1h writes priced at 2x input"
}

test_refuses_rather_than_inventing_when_nothing_matches() {
  _need_jq || return
  local tmp; tmp=$(make_tmp_project); cd "$tmp" || return
  local cfg; cfg=$(_fake_transcript "$tmp/fakehome" "$(pwd)" "2020-01-01T00:00:00.000Z")

  local out rc
  out=$(CLAUDE_CONFIG_DIR="$cfg" "$TOOL" --pricing "$PRICING" --since "$(date +%s)" --tokens 2>/dev/null)
  rc=$?
  assert_eq "3" "$rc" "exit 3 when no usage row falls in the window"
  assert_eq ""  "$out" "prints nothing rather than a zero"
}

test_refuses_when_there_is_no_transcript_at_all() {
  _need_jq || return
  local tmp; tmp=$(make_tmp_project); cd "$tmp" || return
  mkdir -p "$tmp/emptyhome/projects"

  local rc
  CLAUDE_CONFIG_DIR="$tmp/emptyhome" "$TOOL" --pricing "$PRICING" --tokens >/dev/null 2>&1
  rc=$?
  assert_eq "3" "$rc" "exit 3 when no transcript matches this project"
}

test_parses_timestamps_that_carry_milliseconds() {
  # Claude Code writes "...T08:34:33.488Z"; jq's fromdateiso8601 rejects the
  # fraction, which silently filtered out every row before it was stripped.
  _need_jq || return
  local tmp; tmp=$(make_tmp_project); cd "$tmp" || return
  local cfg; cfg=$(_fake_transcript "$tmp/fakehome" "$(pwd)" "$(date -u +%Y-%m-%dT%H:%M:%S.488Z)")

  local out
  out=$(CLAUDE_CONFIG_DIR="$cfg" "$TOOL" --pricing "$PRICING" --since "$(( $(date +%s) - 600 ))" --tokens 2>/dev/null)
  assert_eq "1860" "$out" "a millisecond timestamp still falls inside the window"
}

run_tests "$@"
