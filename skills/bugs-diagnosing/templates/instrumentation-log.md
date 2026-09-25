# {{INVESTIGATION_ID}} — Instrumentation Log

Mode: server | offline   <!-- server: probes POST to the loopback log server → runtime.jsonl. offline: the target cannot reach 127.0.0.1; probes persist on-device under dbg_{{INVESTIGATION_ID}} and are read back into `pasted` entries below — runtime.jsonl stays empty, as expected. -->

> Chronological narrative. One entry per probe added/removed or per significant observation.
> Append-only — never rewrite history; if a hypothesis is wrong, add a new entry that says so.

<!-- Entry format:

## HH:MM — [add probe pN | observe | hypothesis update | remove probe pN]

**Probe:** pN at `path/to/file.ext:42` capturing `[vars]`
**Run:** [what was reproduced]
**Reading:** [excerpt from runtime.jsonl, with line ref]
**Outcome:** confirms H1 | eliminates H1 | inconclusive — [why]
**Next:** [add probe pN+1 | refine H2 | conclude on H1]

-->

## Forwarding remote logs (when the bug is not local)

If the affected process runs on a remote host, forward its log stream into the local debug log server:

```bash
PORT=$(jq -r .port server.json)
ssh user@host 'tail -F /var/log/app.log' \
  | while IFS= read -r line; do
      curl -s -X POST "http://127.0.0.1:${PORT}/log" \
        -H 'content-type: application/json' \
        --data-binary "{\"msg\": $(jq -Rs . <<< "$line")}"
    done
```

If forwarding is not possible, paste excerpts here under a `## HH:MM — pasted` entry and call them out in `findings.md`.

## Offline targets (no route to 127.0.0.1)

Embedded devices, wearables, unattended overnight runs: no server can receive a probe, so none is started. Probes write to one capped on-device debug key or file (`dbg_{{INVESTIGATION_ID}}`); read it back through an in-app diagnostics surface after each repro and paste it here:

```
## HH:MM — pasted (read back from dbg_{{INVESTIGATION_ID}}, run N)
<excerpt>
```

Tag the read-back surface with the `DEBUG:<id>` sentinel so the strip pass removes it, and clear the stored key when the investigation closes.
