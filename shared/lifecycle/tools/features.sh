#!/usr/bin/env bash
# features.sh — which tools each optional feature needs. Sourced, not run.
#
# One table, read by init.sh (never enables a feature whose tools are missing),
# kit.sh's components menu (same rule, and shows "needs …" instead of [off]) and
# doctor.sh (lists what is unavailable here, so an agent can ask the user about
# installing the tool before it asks about the feature).
#
# A feature needs a tool when it cannot be set up or cannot work without it:
#   statusline    jq      installer edits settings JSON; statusline.sh parses its input with jq
#   concise       jq      installer edits settings JSON
#   kitenv        jq      installer edits settings JSON
#   memhook       jq      installer edits settings JSON
#   autoresearch  jq claude   metrics analysis needs jq; the mutation step needs the claude CLI
#   artefacts-dir jq      a custom location is remembered in settings JSON
#   synchooks     jq      the sync hooks are written into settings JSON (sync
#                         itself needs only git; `tlk sync` works without hooks)
#   cli           —       a launcher script; needs nothing beyond bash
#
#   kit_feature_needs KEY     print the tools KEY needs (space-separated)
#   kit_feature_missing KEY   print the needed tools not on PATH; status 1 if any

kit_feature_needs() {
  case "$1" in
    statusline|concise|kitenv|memhook|artefacts-dir|synchooks) echo "jq" ;;
    autoresearch) echo "jq claude" ;;
    *) echo "" ;;
  esac
}

kit_feature_missing() {
  local t out=""
  for t in $(kit_feature_needs "$1"); do
    # _KIT_ASSUME_MISSING (tests only): treat these tools as absent, so the
    # gating can be tested on machines that have them.
    case " ${_KIT_ASSUME_MISSING:-} " in *" $t "*) out+="${out:+ }$t"; continue ;; esac
    command -v "$t" >/dev/null 2>&1 || out+="${out:+ }$t"
  done
  printf '%s' "$out"
  [ -z "$out" ]
}

# Every feature key, for listings.
KIT_FEATURES="statusline concise kitenv memhook autoresearch artefacts-dir synchooks cli"
