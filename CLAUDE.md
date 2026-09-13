# talaka — contributor notes

Guidance for working on the kit itself. (Projects that install the kit get their
own CLAUDE.md block from `shared/lifecycle/tools/init.sh`; this file is not it.)

## Shell scripts must be committed executable

Missing execute bits are a recurring CI failure in this repo. This checkout is
usually on Windows, where `core.fileMode=false`: git records every **new** `.sh`
as `100644` whatever the file looks like locally. Git Bash runs it fine, so it
passes locally and on the Windows runner — then Linux and macOS fail with
`exit 126` (permission denied) deep inside some unrelated test.

- After adding any `.sh` file, before committing:
  ```bash
  git update-index --chmod=+x path/to/new.sh
  git ls-files -s -- '*.sh' | awk '$1 != "100755"'   # must print nothing
  ```
- `chmod +x` alone does nothing here — only `git update-index --chmod=+x` changes
  the recorded mode.
- `tests/lint/structure.test.sh` (`tracked_shell_scripts_are_executable`) fails
  on any tracked `.sh` not at `100755`, naming the file and the fix.

## Tests

- `bash tests/run.sh` runs everything; `bash tests/run.sh <pattern>` filters.
  Requires bash ≥ 4. See `tests/README.md`.
- CI runs ubuntu, macOS (Homebrew bash, BSD userland), Windows (Git Bash) and a
  debian-slim image with no python and no jq. Local green on Windows is not
  enough — keep these in mind:
  - **Optional tools** (jq, python3): a test whose tool needs one must
    `skip_test` when it is absent, not `fail`.
  - **BSD vs GNU:** macOS awk rejects multi-line `-v` values, and `gsub`
    rewrites `&` in the replacement everywhere — prefer bash parameter expansion
    for text substitution.
  - **Paths:** macOS `TMPDIR` ends in `/`. Compare paths only in the normalised
    form `pwd` prints (no `//`, no trailing `/`).
- Reproduce the macOS path shape locally with `TMPDIR=/tmp/ bash tests/run.sh`.
