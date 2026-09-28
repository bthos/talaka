#!/usr/bin/env bash
# run.sh --init installs the metrics toolchain into .tlk/autoresearch/tools/.
# A copy the project edited is kept; a copy nobody touched is refreshed, so an
# install that predates a tool flag the agent prompts now call (--mark-start,
# issue #34) does not silently record null forever.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

RUN="$KIT_ROOT/autoresearch/run.sh"
TPL="$KIT_ROOT/templates/autoresearch/tools"

_init() { ( cd "$1" && ARTEFACTS_DIR="$1/.tlk" bash "$RUN" --init ) >/dev/null 2>&1; }
_blob() { tr -d '\r' < "$1" | git hash-object --stdin; }

_need_git() {
  command -v git >/dev/null 2>&1 && return 0
  skip_test "git absent"
  return 1
}

test_fresh_install_copies_every_tool() {
  _need_git || return
  local proj; proj=$(make_tmp_project)
  _init "$proj"
  local t
  for t in record-metrics.sh collect-usage.sh analyze-metrics.sh fetch-pricing.sh pricing.json; do
    assert_file_exists "$proj/.tlk/autoresearch/tools/$t" "$t installed"
  done
  assert_file_contains "$proj/.tlk/autoresearch/tools/.kit-blobs" "record-metrics.sh" \
    "installed blobs recorded"
}

test_untouched_old_copy_is_refreshed() {
  _need_git || return
  local proj; proj=$(make_tmp_project)
  _init "$proj"
  local dest="$proj/.tlk/autoresearch/tools/record-metrics.sh"
  # Simulate an install from an older kit: the copy is exactly what that kit
  # shipped, and .kit-blobs says so.
  printf '#!/usr/bin/env bash\necho old kit\n' > "$dest"
  printf '%s record-metrics.sh\n' "$(_blob "$dest")" > "$proj/.tlk/autoresearch/tools/.kit-blobs"
  _init "$proj"
  assert_eq "$(_blob "$TPL/record-metrics.sh")" "$(_blob "$dest")" "refreshed to the current template"
  assert_file_contains "$dest" "--mark-start" "the refreshed copy knows --mark-start"
}

test_locally_edited_copy_is_kept() {
  _need_git || return
  local proj; proj=$(make_tmp_project)
  _init "$proj"
  local dest="$proj/.tlk/autoresearch/tools/record-metrics.sh"
  printf '\n# project tweak\n' >> "$dest"
  _init "$proj"
  assert_file_contains "$dest" "# project tweak" "a project edit survives --init"
}

run_tests "$@"
