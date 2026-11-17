> DEPRECATED — see [ComputerUse/README.md](../../../README.md); content
> preserved verbatim below (relocation pointer fixes only, recorded in
> doc_redesign/consolidation/computeruse_deprecation.md).

# ComputerUse user documentation

Agent-facing usage notes for the ComputerUse workflow: what is unique here
versus co-registered with sibling workflows, sandbox differences, and pointers
into the deeper references. The task surface itself (all 36 entries) is in
[Tasks.md](../Tasks.md) (historical, relocated); dependencies, the export surface and
testing are in [doc/developer/README.md](../developer/README.md).

## Task-family duplication map

ComputerUse's 36 registered tasks are almost entirely co-registered with
sibling workflows that own the maintained documentation for the shared
families. Use this map to decide where to read and where the duplication is
intentional:

| Family | Tasks | Also registered on | Where the maintained docs live |
|---|---|---|---|
| Filesystem | `write`, `read`, `list_directory`, `file_stats`, `pwd`, `copy`, `delete`, `search` | Workspace | Workspace/README.md entries; Workspace skills `workspace-files` |
| Exec | `bash`, `python`, `ruby`, `r` | Workspace | Workspace/README.md; skill `workspace-execution` |
| Patch | `patch` | Workspace | Workspace/README.md `## patch` entry (ComputerUse's entry keeps its CLI quick start) |
| TSV | `tsv_info`, `tsv_read`, `tsv_query`, `tsv_edit`, `tsv_merge`, `tsv_attach`, `tsv_translate`, `tsv_sort` | Workspace | [doc/user/TSV.md](TSV.md) here (ComputerUse-specific, historical); maintained reference: Workspace/doc/user/TSV.md |
| Document/web | `searxng`, `docx2md`, `pdf2md`, `pdf2md_full`, `pdf2md_no_images`, `html2md`, `excerpts`, `rag`, `query`, `pdf_query`, `html_query` | Reader | Reader/README.md + Reader/doc/user/README.md; skill `reader-doc-acquisition` |
| Time | `current_time` | Workspace | either; trivial task |
| **ComputerUse-unique** | `kb_register`, `playwright` | — | [Tasks.md](../Tasks.md) entries; [skills/computeruse-doc-conversion](../skills/computeruse-doc-conversion/SKILL.md), [skills/computeruse-playwright](../skills/computeruse-playwright/SKILL.md) |

Two deliberate notes on this map:

- `precise_edit` is documented in Workspace but is **not registered on
  ComputerUse**. ComputerUse ships `lib/ComputerUse/tasks/precise_edit.rb`,
  but `workflow.rb` never requires it, and `ComputerUse.task_info(:precise_edit)`
  raises. Use Workspace for `precise_edit`.
- The duplication itself (filesystem/exec/TSV families duplicated between
  ComputerUse and Workspace; document family duplicated between ComputerUse
  and Reader) is flagged here as documented; whether to deduplicate the code
  belongs to the workflow owners, not to this documentation.

## Sandbox differences versus Workspace

The sandbox model — two permission layers (Ruby allowlist checked in the
filesystem tasks; bwrap mounts for the exec tasks), the writable/readable
path inventory, `BWRAP_PATH`, scratch-file etiquette, output handling and
`stderr_full`, and where job outputs land — is documented authoritatively in
[Workspace/doc/user/SandboxAndOutputs.md](../../../../Workspace/doc/user/SandboxAndOutputs.md).
ComputerUse shares that model; only these points differ or deserve emphasis:

- **PWD-scoped path checks.** Tasks like `read`, `write`, `delete`, `search`
  and `list_directory` check that input paths are under the current process
  working directory (PWD); access to workflow jobs generated during your work
  is also granted. Always use the `/bulk` spelling of the repo root — the
  `/home` alias is a symlink that is not visible inside the Workspace bash
  sandbox.
- **bwrap write locations.** Exec code runs under bwrap with write access to
  the process working directory plus `/tmp`, `~/.rbbt/tmp`, `~/.rbbt/var`,
  `~/.scout/tmp`, `~/.scout/var`, and read access to library/code locations
  such as the user home, `/usr/lib`, `/usr/local/lib`. Tools that want to
  write caches outside these directories should be pointed inside the current
  directory (often via environment variables). When bwrap is unavailable, or
  `BWRAP_PATH=false` is set, tools run unsandboxed.
- **Etiquette.** When generating files with data and scripts, write them under
  a scratch directory like `./tmp`, `./results`, or `./sandbox` rather than
  scattering them in the repository root.
- **`sandbox_paths` example path.** The `sandbox_paths` README entry shows a
  sample output from a different (non-AgentSuite) checkout
  (`/bulk/mvazque2/git/workflows/ComputerUse`). The entry text is retained
  byte-identical for provenance; treat that path as illustrative only, and
  run `sandbox_paths` in your own session for the actual inventory.

## Which document task for which source

The document family is shared with Reader, whose
[doc/user/README.md](../../../../Reader/doc/user/README.md) carries the maintained
"Which task for which source" table. From the ComputerUse side the summary is:
`pdf2md`/`pdf2md_full`/`pdf2md_no_images` (docling) for PDFs, `docx2md`
(Pandoc) for DOCX, `html2md` (html2markdown) for HTML text or URLs, `searxng`
for self-hosted web search, and the retrieval chain `excerpts` → `rag` →
`query` (plus composites `pdf_query`, `html_query`) once you have text. See
[skills/computeruse-doc-conversion/SKILL.md](../skills/computeruse-doc-conversion/SKILL.md)
for the full decision path and `kb_register` for registering association
databases in a Scout KnowledgeBase.

## Playwright browser tests

`playwright` is ComputerUse-unique. It runs a Playwright spec via
`npx playwright` from the workflow root; script files are written under
`.playwright/scripts` and run artifacts land under `.playwright/runs`.
See the `## playwright` entry in [Tasks.md](../Tasks.md) and
[skills/computeruse-playwright/SKILL.md](../skills/computeruse-playwright/SKILL.md).

## TSV tasks

The full ComputerUse TSV reference — ingest flow, task table, data shape,
downstream tasks, mutation safety — is [doc/user/TSV.md](TSV.md).
