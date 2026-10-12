# Handoff Log — {{MAP_ID}}

<!-- The coordinator's event track. No worker invokes another.

Two kinds of entry:

1. Progress — appended mid-run at each meaningful checkpoint. No arrow (you
   have not returned yet), no Recommend: line. Write one when a unit of work is
   done but unverified, when a check produces results, before something long or
   irreversible, or when the plan changes.

## YYYY-MM-DD HH:MM [Worker] [context] progress
Result: ...
Artifacts: ...
Next: ...

2. Return — exactly one, appended immediately before returning.

## YYYY-MM-DD HH:MM [Worker] → Coordinator [context] [done|pass|fail|blocked]
Result: ...
Artifacts: ...
Recommend: [@agent | /skill | STOP — user input needed | END]
Why: ...
Blockers: [None | ...]
-->
