#!/usr/bin/env bash
# Install primitives shared by init.sh (and any future installer).
# Sourced after shared/lifecycle/tools/lib.sh.
#
# Provides:
#   install_kit_copy_file <label> <rel_path> <src_file_abs>
#   install_kit_copy_tree <label> <rel_path> <src_dir_abs>
#
# Both honour the OVERWRITE_ALL/SKIP_ALL/MODE/should_overwrite contract defined
# in init.sh, plus DRY_RUN if the caller sets it. SHA-256 of the kit source is
# computed once and used as the manifest hash after copy (since cp produces an
# identical file, rehashing the target would be redundant).
# shellcheck shell=bash

# Copy kit file into project; record SHA-256 in manifest for teardown.
# Project-patch blocks (<!-- project-patch:start/end -->) are preserved across
# overwrites: extracted before copy, re-appended after.
install_kit_copy_file() {
  local label="$1" rel_path="$2" src_file="$3"
  local target="$PROJECT_ROOT/$rel_path"
  local want have recorded
  local copy_now=false
  local saved_patches=""

  want=$(kit_sha256_file "$src_file") || return 1
  [ -d "${target%/*}" ] || mkdir -p "${target%/*}"
  recorded=$(manifest_get_hash "$rel_path" || true)

  # Branch 1: missing or symlink
  if [ ! -e "$target" ] || [ -L "$target" ]; then
    if [ -L "$target" ] && ! should_overwrite "$label"; then
      skip "$label (exists — use --force to replace)"
      return 1
    fi
    [ -L "$target" ] && rm -rf "$target"
    copy_now=true
  # Branch 2: not a regular file (e.g. dir)
  elif [ ! -f "$target" ]; then
    if ! should_overwrite "$label"; then skip "$label (not a regular file)"; return 1; fi
    rm -rf "$target"
    copy_now=true
  else
    # Before comparing hashes, check if the diff is only project-patch blocks.
    # Strip them to get the "kit-only" content for comparison.
    have=$(kit_sha256_file "$target")
    if [ "$have" = "$want" ]; then
      manifest_set_hash "$rel_path" "$want"
      kit_base_write "$rel_path" "$src_file"
      info "$label (matches kit)"
      return 0
    fi

    # If patches are present, compare the file without them.
    if project_patch_present "$target"; then
      saved_patches=$(project_patch_extract "$target")
      local clean_tmp
      clean_tmp=$(kit_mktemp "tlk-clean") || return 1
      cp "$target" "$clean_tmp"
      project_patch_strip "$clean_tmp" 2>/dev/null || true
      local have_clean
      have_clean=$(kit_sha256_file "$clean_tmp")
      if [ "$have_clean" = "$want" ]; then
        manifest_set_hash "$rel_path" "$have"
        kit_base_write "$rel_path" "$src_file"
        info "$label (matches kit + project patches preserved)"
        return 0
      fi
    fi

    # Branch 3: file exists. Try cheap path: clean git checkout matching kit.
    if [ -n "$recorded" ] && [ "$recorded" = "$want" ] && kit_is_git_clean "$rel_path"; then
      manifest_set_hash "$rel_path" "$want"
      kit_base_write "$rel_path" "$src_file"
      info "$label (matches kit, git-clean)"
      return 0
    fi

    # 3-way merge: carry local edits (Veles ratchets, apply-patches, hand edits)
    # across the kit refresh. Ancestor = the base snapshot from the last install.
    # Skipped under --force/overwrite-all (take kit) and when no ancestor exists.
    local base_file merged mrc
    base_file="$(kit_base_path "$rel_path")"
    if [ "${MODE:-}" != "force" ] && ! $OVERWRITE_ALL && [ -f "$base_file" ]; then
      merged=$(kit_mktemp "tlk-merged") || return 1
      # `|| mrc=$?` keeps a non-zero merge (conflict) from tripping `set -e` in
      # init.sh, and suppresses -e inside the merge helper body too.
      mrc=0
      kit_three_way_merge "$target" "$base_file" "$src_file" "$merged" || mrc=$?
      if [ "$mrc" -eq 0 ]; then
        if cmp -s "$merged" "$target"; then
          kit_base_write "$rel_path" "$src_file"
          manifest_set_hash "$rel_path" "$have"
          info "$label (up to date; local edits kept)"
        else
          cp "$merged" "$target"
          kit_base_write "$rel_path" "$src_file"
          manifest_set_hash "$rel_path" "$(kit_sha256_file "$target")"
          success "$label (merged: kit update + local edits)"
        fi
        return 0
      elif [ "$mrc" -eq 1 ]; then
        local decision="skip"
        if [ "${MODE:-}" != "skip" ] && [ -t 0 ] && declare -F ask_merge_conflict >/dev/null; then
          ask_merge_conflict "$label" "$merged"; decision="$MERGE_DECISION"
        fi
        case "$decision" in
          merged)
            cp "$merged" "$target"
            kit_base_write "$rel_path" "$src_file"
            manifest_set_hash "$rel_path" "$(kit_sha256_file "$target")"
            warn "$label (merged WITH CONFLICT MARKERS — resolve <<<<<<< in $rel_path)"
            return 0 ;;
          theirs)
            rm -f "$target"; cp "$src_file" "$target"
            kit_base_write "$rel_path" "$src_file"
            manifest_set_hash "$rel_path" "$want"
            success "$label (took kit version)"
            return 0 ;;
          ours|skip|*)
            # Keep local; DO NOT advance base (local does not reflect newkit yet,
            # so re-attempt on the next update). Drop the incoming kit for review.
            mkdir -p "$KIT_CONFLICTS_DIR/$(dirname "$rel_path")" 2>/dev/null || true
            cp "$src_file" "$KIT_CONFLICTS_DIR/$rel_path.newkit" 2>/dev/null || true
            warn "$label (merge conflict — kept local; incoming kit → $ARTEFACTS_NAME/.conflicts/$rel_path.newkit)"
            return 1 ;;
        esac
      fi
      # mrc >= 2 → merge unavailable; fall through to legacy skip/overwrite.
    fi

    if [ -n "$recorded" ] && [ "$have" = "$recorded" ]; then
      if ! should_overwrite "$label" "$target" "$src_file"; then
        skip "$label (kit updated in submodule — use --force to refresh)"
        return 1
      fi
      rm -f "$target"; copy_now=true
      _post_label="(refreshed from kit)"
    elif [ -n "$recorded" ] && [ "$have" != "$recorded" ]; then
      if ! should_overwrite "$label" "$target" "$src_file"; then
        skip "$label (modified locally — use --force to replace)"
        return 1
      fi
      rm -f "$target"; copy_now=true
      _post_label="(overwritten)"
    else
      if ! should_overwrite "$label" "$target" "$src_file"; then
        skip "$label (exists — use --force)"
        return 1
      fi
      rm -f "$target"; copy_now=true
      _post_label="(overwritten)"
    fi
  fi

  if $copy_now; then
    cp "$src_file" "$target"
    kit_base_write "$rel_path" "$src_file"
    # Re-append project patches that were saved before overwrite
    if [ -n "$saved_patches" ]; then
      printf '\n%s\n' "$saved_patches" >> "$target"
      _post_label="${_post_label:-} + patches preserved"
    fi
    # cp reproduces the source byte for byte, so its hash is $want — rehash
    # only when patches were appended after the copy.
    local final_hash="$want"
    [ -n "$saved_patches" ] && final_hash=$(kit_sha256_file "$target")
    manifest_set_hash "$rel_path" "$final_hash"
    success "$label ${_post_label:-}"
    unset _post_label
  fi
  return 0
}

# Copy skill directory tree; record aggregate SHA-256 of all files.
# Project-patch blocks in .md files within the tree are preserved across overwrites.
install_kit_copy_tree() {
  local label="$1" rel_path="$2" src_dir="$3"
  local target="$PROJECT_ROOT/$rel_path"
  local want have recorded
  local copy_now=false
  local saved_patches_dir=""

  want=$(kit_sha256_tree "$src_dir") || return 1
  [ -d "${target%/*}" ] || mkdir -p "${target%/*}"
  recorded=$(manifest_get_hash "$rel_path" || true)

  if [ ! -e "$target" ] || [ -L "$target" ]; then
    if [ -L "$target" ] && ! should_overwrite "$label"; then
      skip "$label (exists — use --force to replace)"
      return 1
    fi
    [ -L "$target" ] && rm -rf "$target"
    copy_now=true
  elif [ ! -d "$target" ]; then
    if ! should_overwrite "$label"; then skip "$label (not a directory)"; return 1; fi
    rm -rf "$target"
    copy_now=true
  else
    have=$(kit_sha256_tree "$target")
    if [ "$have" = "$want" ]; then
      manifest_set_hash "$rel_path" "$want"
      kit_base_write "$rel_path" "$src_dir"
      info "$label (matches kit)"
      return 0
    fi

    # 3-way merge the skill tree file-by-file, carrying local edits across the
    # refresh. Ancestor = the base snapshot from the last install. Skipped under
    # --force/overwrite-all and when no ancestor tree exists.
    local base_dir merged_dir trc
    base_dir="$(kit_base_path "$rel_path")"
    if [ "${MODE:-}" != "force" ] && ! $OVERWRITE_ALL && [ -d "$base_dir" ]; then
      merged_dir=$(kit_mktemp -d "tlk-merged-tree") || return 1
      trc=0
      kit_three_way_merge_tree "$target" "$base_dir" "$src_dir" "$merged_dir" || trc=$?
      if [ "$trc" -eq 0 ]; then
        rm -rf "$target"; cp -R "$merged_dir" "$target"
        kit_base_write "$rel_path" "$src_dir"
        manifest_set_hash "$rel_path" "$(kit_sha256_tree "$target")"
        success "$label (merged: kit update + local edits)"
        return 0
      elif [ "$trc" -eq 1 ]; then
        local decision="skip"
        if [ "${MODE:-}" != "skip" ] && [ -t 0 ] && declare -F ask_merge_conflict >/dev/null; then
          ask_merge_conflict "$label (skill)" "$merged_dir"; decision="$MERGE_DECISION"
        fi
        case "$decision" in
          merged)
            rm -rf "$target"; cp -R "$merged_dir" "$target"
            kit_base_write "$rel_path" "$src_dir"
            manifest_set_hash "$rel_path" "$(kit_sha256_tree "$target")"
            warn "$label (merged WITH CONFLICT MARKERS — resolve <<<<<<< under $rel_path)"
            return 0 ;;
          theirs)
            rm -rf "$target"; cp -R "$src_dir" "$target"
            kit_base_write "$rel_path" "$src_dir"
            manifest_set_hash "$rel_path" "$want"
            success "$label (took kit version)"
            return 0 ;;
          ours|skip|*)
            mkdir -p "$KIT_CONFLICTS_DIR/$rel_path.newkit" 2>/dev/null || true
            cp -R "$src_dir"/. "$KIT_CONFLICTS_DIR/$rel_path.newkit/" 2>/dev/null || true
            warn "$label (merge conflict — kept local; incoming kit → $ARTEFACTS_NAME/.conflicts/$rel_path.newkit)"
            return 1 ;;
        esac
      fi
      # trc >= 2 → merge unavailable; fall through to legacy skip/overwrite.
    fi

    if [ -n "$recorded" ] && [ "$have" = "$recorded" ]; then
      if ! should_overwrite "$label"; then
        skip "$label (kit skill updated — use --force)"
        return 1
      fi
      copy_now=true
      _post_label="(refreshed from kit)"
    elif [ -n "$recorded" ] && [ "$have" != "$recorded" ]; then
      if ! should_overwrite "$label"; then
        skip "$label (modified locally — use --force)"
        return 1
      fi
      copy_now=true
      _post_label="(overwritten)"
    else
      if ! should_overwrite "$label"; then
        skip "$label (exists — use --force)"
        return 1
      fi
      copy_now=true
      _post_label="(overwritten)"
    fi
  fi

  if $copy_now; then
    # Save project-patch blocks from .md files before overwriting. A fresh
    # install has no target and so nothing to save.
    if [ -d "$target" ]; then
      saved_patches_dir=$(kit_mktemp -d "tlk-tree-patches") || true
    fi
    if [ -n "$saved_patches_dir" ] && [ -d "$target" ]; then
      local md_file
      for md_file in "$target"/*.md; do
        [ -f "$md_file" ] || continue
        if project_patch_present "$md_file"; then
          project_patch_extract "$md_file" > "$saved_patches_dir/$(basename "$md_file")"
        fi
      done
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then rm -rf "$target"; fi
    cp -R "$src_dir" "$target"
    kit_base_write "$rel_path" "$src_dir"

    # Re-append saved project patches
    local had_patches=false
    if [ -d "$saved_patches_dir" ]; then
      local patch_file
      for patch_file in "$saved_patches_dir"/*.md; do
        [ -f "$patch_file" ] || continue
        local target_md="$target/$(basename "$patch_file")"
        if [ -f "$target_md" ]; then
          printf '\n' >> "$target_md"
          cat "$patch_file" >> "$target_md"
          had_patches=true
        fi
      done
    fi

    local final_hash="$want"
    $had_patches && final_hash=$(kit_sha256_tree "$target")
    manifest_set_hash "$rel_path" "$final_hash"
    if $had_patches; then
      _post_label="${_post_label:-} + patches preserved"
    fi
    success "$label ${_post_label:-}"
    unset _post_label
  fi
  return 0
}
