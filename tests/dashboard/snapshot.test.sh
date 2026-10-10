#!/usr/bin/env bash
# Tests for dashboard/tools/snapshot.sh — the collector behind the dashboard page —
# and for the page's offline guarantee.
#
# The snapshot must be lossless (a chunk is the whole file, escaped for a JS
# template literal), incremental (unchanged files are not rewritten), and must
# never list the kit's machinery or its own output. Round-trips through a JS
# engine need node; without it those tests skip and the bash-level checks remain.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

SNAP="$KIT_ROOT/dashboard/tools/snapshot.sh"

_proj() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/.tlk/features/2026-10-01-login" "$proj/.tlk/memory"
  printf '## 10:00 Cmok → Coordinator [build] done\nResult: ok\n' > "$proj/.tlk/features/2026-10-01-login/handoff-log.md"
  printf '%s' "$proj"
}
_snap() { ( cd "$1" && bash "$SNAP" "${@:2}" ); }
# _chunk PROJ REL → path of the chunk file holding REL (from the manifest).
_chunk() {
  local id
  id=$(grep -F "[\"$2\"," "$1/.tlk/dashboard/manifest.js" | sed 's/.*,\([0-9][0-9]*\)\]\(,\)\{0,1\}$/\1/')
  printf '%s/.tlk/dashboard/data/c%s.js' "$1" "$id"
}
# _js_same CHUNKFILE ORIGINAL → empty when the text the page would see equals the
# file byte for byte; otherwise the first differing offset with both sides
# around it. Compared inside node, so no shell pipe or locale sits in between.
_js_same() {
  node -e '
    const fs = require("fs"); let out;
    global.TLK = { chunk: (p, t) => { out = t } };
    require(process.argv[1]);
    const got = Buffer.from(out, "utf8"), want = fs.readFileSync(process.argv[2]);
    if (got.equals(want)) process.exit(0);
    let i = 0; while (i < got.length && i < want.length && got[i] === want[i]) i++;
    const ctx = b => JSON.stringify(b.subarray(Math.max(0, i - 12), i + 12).toString("latin1"));
    console.log(`differs at byte ${i} (page ${got.length} B, file ${want.length} B): page ${ctx(got)} file ${ctx(want)}`);
  ' "$1" "$2"
}

test_writes_manifest_chunks_and_page() {
  local proj; proj=$(_proj)
  local out; out=$(_snap "$proj" 2>&1) || fail "snapshot exited non-zero: $out"
  assert_file_exists "$proj/.tlk/dashboard/manifest.js"
  assert_file_exists "$proj/.tlk/dashboard/index.html" "viewer copied next to the data"
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" '".tlk/features/2026-10-01-login/handoff-log.md"'
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" '"artefacts":".tlk"'
  assert_file_exists "$(_chunk "$proj" .tlk/features/2026-10-01-login/handoff-log.md)"
  assert_contains "$out" "1 chunk(s) written"
}

test_manifest_root_is_the_normalised_pwd() {
  # macOS TMPDIR ends in "/": the root must be what `pwd` prints, never ".../T//…".
  # Git Bash records the Windows form (C:/…) so editor links open; `pwd -W` prints it.
  local proj; proj=$(_proj)
  _snap "$proj" >/dev/null 2>&1
  local want; want=$(cd "$proj" && { pwd -W 2>/dev/null || pwd; })
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" "\"root\":\"$want\""
}

test_special_characters_are_escaped() {
  local proj; proj=$(_proj)
  printf 'a `b` ${c} \\d\r\nend' > "$proj/.tlk/features/2026-10-01-login/spec.md"
  _snap "$proj" >/dev/null 2>&1
  local c; c=$(_chunk "$proj" .tlk/features/2026-10-01-login/spec.md)
  assert_file_contains "$c" 'a \`b\` \${c} \\d\r'
}

test_chunk_round_trips_through_js() {
  command -v node >/dev/null 2>&1 || { skip_test "node not installed"; return; }
  local proj; proj=$(_proj)
  local f="$proj/.tlk/features/2026-10-01-login/spec.md"
  printf 'a `b` ${c} \\d \\` \\${x}\r\n\ttab ünïcode\n\n' > "$f"
  _snap "$proj" >/dev/null 2>&1
  assert_eq "" "$(_js_same "$(_chunk "$proj" .tlk/features/2026-10-01-login/spec.md)" "$f")" \
    "page sees the file byte for byte"
}

test_large_file_round_trips_through_js() {
  # Over 32 KB the escaping moves from bash to sed; the result must be the same.
  command -v node >/dev/null 2>&1 || { skip_test "node not installed"; return; }
  local proj; proj=$(_proj)
  local f="$proj/.tlk/features/2026-10-01-login/metrics.jsonl" i
  for i in $(seq 1 1500); do printf '{"n":%d,"s":"`x` ${y} \\\\z"}\r\n' "$i"; done > "$f"
  [ "$(wc -c < "$f")" -gt 32768 ] || fail "fixture is not over 32 KB"
  _snap "$proj" >/dev/null 2>&1
  local c; c=$(_chunk "$proj" .tlk/features/2026-10-01-login/metrics.jsonl)
  assert_eq "" "$(_js_same "$c" "$f")" "large file round-trips"
}

test_second_run_writes_nothing() {
  local proj; proj=$(_proj)
  _snap "$proj" >/dev/null 2>&1
  local c; c=$(_chunk "$proj" .tlk/features/2026-10-01-login/handoff-log.md)
  touch -t 200001010000 "$c"
  local out; out=$(_snap "$proj" 2>&1)
  assert_contains "$out" "0 chunk(s) written"
  [ "$c" -nt "$proj/.tlk/features/2026-10-01-login/handoff-log.md" ] && fail "unchanged chunk was rewritten" || true
}

test_changed_file_rewrites_only_its_chunk() {
  local proj; proj=$(_proj)
  printf 'one\n' > "$proj/.tlk/memory/decisions.md"
  _snap "$proj" >/dev/null 2>&1
  printf 'two\n' >> "$proj/.tlk/memory/decisions.md"
  local out; out=$(_snap "$proj" 2>&1)
  assert_contains "$out" "1 chunk(s) written"
  assert_file_contains "$(_chunk "$proj" .tlk/memory/decisions.md)" "two"
}

test_deleted_file_drops_entry_and_chunk() {
  local proj; proj=$(_proj)
  printf 'x\n' > "$proj/.tlk/memory/system.md"
  _snap "$proj" >/dev/null 2>&1
  local c; c=$(_chunk "$proj" .tlk/memory/system.md)
  assert_file_exists "$c"
  rm "$proj/.tlk/memory/system.md"
  _snap "$proj" >/dev/null 2>&1
  assert_file_absent "$c" "stale chunk removed"
  assert_file_not_contains "$proj/.tlk/dashboard/manifest.js" "memory/system.md"
}

test_chunk_ids_are_stable_across_runs() {
  local proj; proj=$(_proj)
  _snap "$proj" >/dev/null 2>&1
  local before; before=$(_chunk "$proj" .tlk/features/2026-10-01-login/handoff-log.md)
  printf 'x\n' > "$proj/.tlk/memory/aaa.md"
  _snap "$proj" >/dev/null 2>&1
  assert_eq "$before" "$(_chunk "$proj" .tlk/features/2026-10-01-login/handoff-log.md)" "id kept when another file appears"
}

test_binary_file_is_listed_without_a_chunk() {
  local proj; proj=$(_proj)
  printf '\x89PNG\x00\x01' > "$proj/.tlk/features/2026-10-01-login/shot.png"
  _snap "$proj" >/dev/null 2>&1
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" '/shot.png",6,'
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" ',null]'
}

test_wiki_is_included_and_dir_is_configurable() {
  local proj; proj=$(_proj)
  mkdir -p "$proj/wiki/pages" "$proj/docs/kb/pages"
  printf '# A\n' > "$proj/wiki/pages/a.md"
  printf '# B\n' > "$proj/docs/kb/pages/b.md"
  _snap "$proj" >/dev/null 2>&1
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" '"wiki/pages/a.md"'
  ( cd "$proj" && TALAKA_WIKI_DIR=docs/kb bash "$SNAP" >/dev/null 2>&1 )
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" '"docs/kb/pages/b.md"'
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" '"wiki":"docs/kb"'
}

test_kit_machinery_and_own_output_are_not_listed() {
  local proj; proj=$(_proj)
  mkdir -p "$proj/.tlk/autoresearch/runs" "$proj/.tlk/autoresearch/variants/r1" "$proj/.tlk/.base"
  printf '1\n' > "$proj/.tlk/autoresearch/runs/.start-cmok"
  printf '{}\n' > "$proj/.tlk/autoresearch/runs/ratchet.jsonl"
  printf 'x\n' > "$proj/.tlk/autoresearch/variants/r1/cmok.md"
  printf 'x\n' > "$proj/.tlk/.base/cmok.md"
  printf 'x\n' > "$proj/.tlk/memory/a.md.tmp.123"
  _snap "$proj" >/dev/null 2>&1
  _snap "$proj" >/dev/null 2>&1
  local m="$proj/.tlk/dashboard/manifest.js"
  assert_file_contains "$m" "runs/ratchet.jsonl"
  assert_file_not_contains "$m" ".start-cmok"
  assert_file_not_contains "$m" "variants/"
  assert_file_not_contains "$m" ".base/"
  assert_file_not_contains "$m" ".tmp."
  assert_file_not_contains "$m" "dashboard/"
}

test_odd_paths_are_valid_json() {
  local proj; proj=$(_proj)
  local d="$proj/.tlk/features/2026-10-02-it's \"quoted\" & spaced"
  mkdir -p "$d" 2>/dev/null || { skip_test "filesystem rejects '\"' in names (Windows)"; return; }
  printf 'x\n' > "$d/spec.md"
  _snap "$proj" >/dev/null 2>&1
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" 'it'"'"'s \"quoted\" & spaced/spec.md'
  if command -v node >/dev/null 2>&1; then
    node -e 'let m;global.TLK={manifest:x=>{m=x}};require(process.argv[1]);if(!m.files.some(f=>f[0].includes("\"quoted\"")))process.exit(1)' \
      "$proj/.tlk/dashboard/manifest.js" || fail "manifest does not parse, or lost the quoted path"
  fi
}

test_absolute_artefacts_dir_gives_relative_paths() {
  local proj; proj=$(_proj)
  ( cd "$proj" && ARTEFACTS_DIR="$(pwd)/.tlk" bash "$SNAP" >/dev/null 2>&1 )
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" '[".tlk/features/2026-10-01-login/handoff-log.md",'
}

test_fails_cleanly_without_artefacts_dir() {
  local proj; proj=$(make_tmp_project)
  local out rc=0; out=$(_snap "$proj" 2>&1) || rc=$?
  assert_eq "1" "$rc" "exit 1 when .tlk/ is missing"
  assert_contains "$out" "not found"
}

test_live_lock_makes_a_second_run_leave() {
  local proj; proj=$(_proj)
  mkdir -p "$proj/.tlk/dashboard/.lock"
  printf '%s\n' "$$" > "$proj/.tlk/dashboard/.lock/pid"
  local out rc=0; out=$(_snap "$proj" 2>&1) || rc=$?
  assert_eq "0" "$rc"
  assert_contains "$out" "in progress"
  assert_file_absent "$proj/.tlk/dashboard/manifest.js" "did not write while locked"
}

test_stale_lock_is_taken_over() {
  local proj; proj=$(_proj)
  mkdir -p "$proj/.tlk/dashboard/.lock"
  # A pid that cannot be running: past pid_max on every platform the kit supports.
  printf '99999999\n' > "$proj/.tlk/dashboard/.lock/pid"
  _snap "$proj" >/dev/null 2>&1 || fail "snapshot failed with a stale lock"
  assert_file_exists "$proj/.tlk/dashboard/manifest.js"
  [ -d "$proj/.tlk/dashboard/.lock" ] && fail "lock left behind" || true
}

test_tick_refreshes_only_an_existing_snapshot() {
  local proj; proj=$(_proj)
  install_kit_into "$proj"
  ( cd "$proj" && bash talaka/memory/tools/init.sh >/dev/null 2>&1 )
  ( cd "$proj" && bash talaka/memory/tools/tick.sh >/dev/null 2>&1 )
  assert_file_absent "$proj/.tlk/dashboard/manifest.js" "tick does not create a dashboard nobody asked for"
  _snap "$proj" >/dev/null 2>&1
  printf 'x\n' > "$proj/.tlk/features/2026-10-01-login/spec.md"
  ( cd "$proj" && bash talaka/memory/tools/tick.sh >/dev/null 2>&1 )
  assert_file_contains "$proj/.tlk/dashboard/manifest.js" "2026-10-01-login/spec.md" "tick refreshed the snapshot"
}

test_kit_menu_offers_the_dashboard() {
  local proj; proj=$(make_tmp_project)
  mkdir -p "$proj/talaka"
  cp "$KIT_ROOT/kit.sh" "$proj/talaka/"
  local out; out=$(bash "$proj/talaka/kit.sh" --list-json 2>&1)
  assert_contains "$out" '"key":"dashboard"'
}

test_viewer_makes_no_external_requests() {
  # The page runs from file:// and offline; it must not reach for a CDN, a font
  # host or an API.
  local v="$KIT_ROOT/dashboard/viewer.html"
  assert_file_exists "$v"
  local hits
  hits=$(grep -nE '(src|href)=["'"'"']?(https?:)?//|@import|url\((["'"'"'])?https?:|fetch\(|XMLHttpRequest|new WebSocket' "$v" \
    | grep -v 'href="vscode://' || true)
  assert_eq "" "$hits" "no external requests in viewer.html"
}

run_tests "$@"
