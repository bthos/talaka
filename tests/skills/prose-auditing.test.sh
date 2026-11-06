#!/usr/bin/env bash
# prose-auditing — scan-prose.sh candidate listing (files and --diff).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

SCAN="$KIT_ROOT/skills/prose-auditing/scan-prose.sh"

_doc() {
  write_file "$1/README.md" <<'MD'
# Widget

In today's fast-paced world, Widget is a robust tool.

```bash
# we leverage this inside a fence
```

Pass `--leverage` to enable it. Let's dive in!
It's important to note that it is not just fast, but also small.
<!-- seamless --> Plain sentence.

## In Summary
Happy coding!
MD
}

test_scan_lists_candidates_with_line_id_excerpt_fix() {
  local proj out; proj=$(make_tmp_project); _doc "$proj"
  out=$( cd "$proj" && bash "$SCAN" README.md )
  assert_contains "$out" "README.md:3	canned-opener	in today's	"
  assert_contains "$out" "README.md:3	hollow-adjective	robust	"
  assert_contains "$out" "README.md:9	lets-dive	let's dive	"
  assert_contains "$out" "README.md:10	importance-hedge	it's important to note	"
  assert_contains "$out" "README.md:10	not-just-but	not just fast, but also	"
  assert_contains "$out" "README.md:13	recap-ending	in summary	" "headings count, case-insensitive"
  assert_contains "$out" "README.md:14	sign-off	happy coding	"
  assert_contains "$out" "FINDINGS=7 FILES=1"
}

test_scan_skips_code_and_comments() {
  local proj out; proj=$(make_tmp_project); _doc "$proj"
  out=$( cd "$proj" && bash "$SCAN" README.md )
  assert_not_contains "$out" "README.md:6" "fenced code is skipped"
  assert_not_contains "$out" "README.md:9	leverage" "inline code is skipped"
  assert_not_contains "$out" "README.md:11" "an HTML comment is skipped"
}

test_scan_diff_only_added_lines_and_untracked_docs() {
  local proj out; proj=$(make_tmp_project); _doc "$proj"
  write_file "$proj/src/app.js" <<< '// a robust app'
  ( cd "$proj" && git add -A && git commit -qm init )
  printf '\nWe leverage seamless sync.\n' >> "$proj/README.md"
  echo '// leverage it' >> "$proj/src/app.js"
  write_file "$proj/docs/NEW.md" <<< 'A comprehensive guide.'
  out=$( cd "$proj" && bash "$SCAN" --diff )
  assert_contains "$out" "README.md:16	inflated-adjective	seamless	"
  assert_contains "$out" "README.md:16	leverage	leverage	"
  assert_contains "$out" "docs/NEW.md:1	hollow-adjective	comprehensive	" "untracked docs are scanned whole"
  assert_not_contains "$out" "README.md:3" "untouched lines are not audited"
  assert_not_contains "$out" "app.js" "code files are not docs"
  assert_contains "$out" "FINDINGS=3 FILES=2"

  ( cd "$proj" && git add -A && git commit -qm docs )
  out=$( cd "$proj" && bash "$SCAN" --diff HEAD~1 )
  assert_contains "$out" "README.md:16	leverage" "a base before the commit still sees it"
  out=$( cd "$proj" && bash "$SCAN" --diff )
  assert_eq "FINDINGS=0 FILES=0" "$out" "nothing uncommitted, nothing to audit"
}

test_scan_errors() {
  local proj; proj=$(make_tmp_project)
  ( cd "$proj" && bash "$SCAN" ) >/dev/null 2>&1; assert_eq 2 $? "no arguments is a usage error"
  ( cd "$proj" && bash "$SCAN" nope.md ) >/dev/null 2>&1; assert_eq 1 $? "missing file"
  ( cd "$proj" && bash "$SCAN" --diff nope ) >/dev/null 2>&1; assert_eq 1 $? "unknown base"
}

test_patterns_file_is_well_formed() {
  local id re fix n=0 bad=""
  while IFS=$'\t' read -r id re fix || [ -n "$id" ]; do
    case "$id" in ""|\#*) continue ;; esac
    n=$((n + 1))
    [ -n "$re" ] && [ -n "$fix" ] || bad+=" $id(fields)"
    [ "$re" = "${re,,}" ] || bad+=" $id(upper-case regex never matches)"
    [[ "x" =~ $re ]]; [ $? -le 1 ] || bad+=" $id(invalid regex)"
  done < "$KIT_ROOT/skills/prose-auditing/patterns.tsv"
  assert_eq "" "$bad" "every pattern: id, lower-case valid ERE, fix"
  [ "$n" -ge 10 ] || fail "only $n patterns"
}

run_tests "$@"
