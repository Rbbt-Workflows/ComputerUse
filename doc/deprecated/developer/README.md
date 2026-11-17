> DEPRECATED — see [ComputerUse/README.md](../../../README.md); content
> preserved verbatim below (relocation pointer fixes only, recorded in
> doc_redesign/consolidation/computeruse_deprecation.md).

# ComputerUse developer documentation

Developer-facing material for ComputerUse: dependency and environment
requirements, the export surface, and testing. The task surface itself — what
each of the 36 registered tasks does and how to call it — is documented in
[Tasks.md](../Tasks.md) (historical, relocated); agent-facing usage notes are in
[doc/user/README.md](../user/README.md).

ComputerUse is not standalone: 29 of its 36 tasks are co-registered with
Workspace and Reader (see the duplication map in
[doc/user/README.md](../user/README.md)). Where shared semantics are involved,
this page records only the ComputerUse specifics and defers to the sibling
documentation.

## Dependencies and environment

Runtime:

- Ruby and the Scout/Rbbt environment — the workflow extends `Workflow`
  (`require 'scout'`, `require 'scout-ai'`), and the tasks rely on Scout
  helpers `CMD` and `Open` plus a bwrap sandbox when available.
- `kb_register` requires `scout/knowledge_base`.

Optional external CLIs, per task family:

| Task(s) | External dependency |
|---|---|
| `pdf2md`, `pdf2md_full`, `pdf2md_no_images`, `pdf_query` | docling CLI (PDF → Markdown) |
| `html2md`, `html_query` | html2markdown CLI |
| `docx2md` | Pandoc (DOCX → Markdown) |
| `searxng` | a SearXNG instance, via `SEARXNG_URL` or the `searxng_url` input |
| `excerpts`, `rag`, `query` | Scout AI helpers (`scout-ai`) for embeddings/retrieval |
| `playwright` | npx playwright (installed project-wide), for browser test runs |

Code execution (`bash`, `python`, `ruby`, `r`, `patch`) is run through bwrap
when available; see [Workspace/doc/user/SandboxAndOutputs.md](../../../../Workspace/doc/user/SandboxAndOutputs.md)
for the execution model. When bwrap is unavailable — or explicitly disabled by
setting `BWRAP_PATH=false` — tools execute unsandboxed.

## Output notes

Document conversion tasks return Markdown text or produce Markdown files under
the task temporary area. The `patch` task returns a structured JSON result
(stdout, stderr, exit_status, generated_patch, used_strip, tried_strips,
applied flags). The exec tasks (`bash`/`python`/`ruby`/`r`) return stdout,
stderr and exit status as JSON; on failure or very large error streams the
`stderr` field is condensed to a root-cause-first view while the complete,
uncondensed stream is preserved on disk and its path returned in the additional
`stderr_full` field. This output-handling contract is shared with Workspace;
the current authority is
[Workspace/doc/user/SandboxAndOutputs.md](../../../../Workspace/doc/user/SandboxAndOutputs.md)
("Output handling and `stderr_full`").

## Export surface

ComputerUse registers 36 tasks. The agent tool surface (`tool: ComputerUse`)
exposes the exported tasks; `export_exec :current_time` is the sole
exec-exported task. Seven retrieval converters — `pdf2md`, `pdf2md_full`,
`pdf2md_no_images`, `excerpts`, `rag`, `query`, `pdf_query` — are not exported
and are reachable only through the workflow runner or programmatic calls.
Verified export list: 29 unique names — bash, copy, current_time, delete,
docx2md, file_stats, html2md, html_query, kb_register, list_directory, patch,
playwright, pwd, python, r, read, ruby, sandbox_paths, search, searxng, and
the eight `tsv_*` tasks (tsv_info, tsv_read, tsv_query, tsv_edit, tsv_merge,
tsv_attach, tsv_translate, tsv_sort).

Cross-registration:

- Workspace registers the same filesystem/exec/patch/TSV tasks
  (`lib/Workspace/tasks/`: filesystem.rb, exec.rb, patch.rb, precise_edit.rb,
  tsv.rb) plus `current_time`. `precise_edit` is registered on Workspace but
  **not** on ComputerUse — ComputerUse ships a `tasks/precise_edit.rb` file
  that `workflow.rb` never requires.
- Reader registers the same 11-task document/web family
  (`lib/Reader/tasks/documents.rb`, `web.rb`) plus `docx2md`; Reader is the
  maintained home of that family's documentation.

## Testing

Test files live under `test/ComputerUse/tasks/`:
`test_exec_helpers.rb`, `test_kb_register.rb`, `test_patch.rb`,
`test_precise_edit.rb`, `test_tsv.rb`. Run one suite from the ComputerUse
checkout with:

```
cd ComputerUse && ruby -Itest test/ComputerUse/tasks/test_tsv.rb
```

Known pre-existing failures at baseline (not introduced by documentation work;
re-verified 2026-11-14): `test_tsv.rb` has failures in
`test_read_returns_normalized_tsv_text_for_list_source` and
`test_query_returns_json_records_in_request_order`; `test_precise_edit.rb`
errors with `No 'precise_edit' task in 'ComputerUse' Workflow` because
`precise_edit` is not registered on ComputerUse. `test_exec_helpers.rb`,
`test_patch.rb` and `test_kb_register.rb` pass.
