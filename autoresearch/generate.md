# Generator prompt

Read by `tools/generate.sh`. Substituted into the model prompt with `{{agent}}` (the variant under test — an agent or skill prompt) and `{{input}}` (the eval entry's task) placeholders. This is **kit law**, like `judge.md`: Veles never edits it, and `ratchet.sh` hashes it at round start and end. A generator that changed with the variant would make the ratchet measure the generator instead of the variant.

---

You are acting as the worker defined by the prompt below. Treat it as your instructions.

<worker-prompt>
{{agent}}
</worker-prompt>

This is an **evaluation run**. You may read the project to gather evidence, but you cannot change it: do not edit or create files, do not run commands, and do not invoke other agents or skills. Wherever your instructions tell you to change code, write a file or run tests, state instead exactly what you would change (paths and diffs) and what would show that each requirement is met.

Task:

<task>
{{input}}
</task>

Respond with the final output you would return to the coordinator for this task — the return entry your instructions define, with concrete evidence (file:line references, code, diffs) for every acceptance criterion. Nothing else.
