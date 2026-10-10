# shellcheck shell=bash
# 001 — the archive keeps one folder per kind.
#
# Zlydni used to archive a feature straight into archive/<YYYY-MM-DD-slug>/, next
# to Yaga's archive/debug/. Features now live in archive/features/<slug>/, and
# every kit tool reads only that. Move each date-named folder under archive/
# into archive/features/. A name already taken there is left in place with a
# warning — two copies of one feature are for a person to merge, not a script.
#
# Sourced by kit_run_migrations (lib.sh) in a subshell with `set -e`.

archive="$ARTEFACTS/archive"
moved=0
if [ -d "$archive" ]; then
  for d in "$archive"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; name="${d##*/}"
    if [ -e "$archive/features/$name" ]; then
      warn "$ARTEFACTS_NAME/archive/$name not moved: archive/features/$name already exists — merge them by hand"
      continue
    fi
    mkdir -p "$archive/features"
    mv "$d" "$archive/features/$name"
    moved=$((moved + 1))
  done
fi
[ "$moved" -eq 0 ] || info "moved $moved archived feature(s) → $ARTEFACTS_NAME/archive/features/"
