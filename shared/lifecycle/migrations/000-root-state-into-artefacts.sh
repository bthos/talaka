# shellcheck shell=bash
# 000 — the kit's install state lives under the artefacts dir.
#
# Older installs kept .talaka.cfg (saved choices, pipeline template SHA) and
# .talaka.files (SHA-256 of every kit-managed copy) in the project root. Both
# now live in $ARTEFACTS_NAME/. Move each one across unless the new path is
# already taken — then the root copy is left alone with a warning.
#
# Run by kit_run_migrations (lib.sh) in its own bash process with `set -e`.
# update.sh and teardown.sh run the migrations before they read either file.

for name in cfg files; do
  old="$PROJECT_ROOT/.${KIT_SLUG}.$name"
  new="$ARTEFACTS/.${KIT_SLUG}.$name"
  [ -f "$old" ] || continue
  if [ -e "$new" ]; then
    warn ".${KIT_SLUG}.$name not moved: $ARTEFACTS_NAME/.${KIT_SLUG}.$name already exists — remove the root copy by hand"
    continue
  fi
  mkdir -p "$ARTEFACTS"
  mv "$old" "$new"
  info "migrated .${KIT_SLUG}.$name → $ARTEFACTS_NAME/.${KIT_SLUG}.$name"
done
