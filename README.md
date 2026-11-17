ComputerUse (deprecated) — succeeded by Reader and Workspace

ComputerUse is deprecated and unmaintained. Do not build on it: every
capability is either maintained by a successor workflow or explicitly
unresolved (below). The workflow still registers its 36 tasks and they
remain callable, but nothing here is maintained.

**Successors.** Document and web acquisition is documented by
[Reader](../Reader/README.md): [Reader/doc/user/README.md](../Reader/doc/user/README.md)
(which task for which source, retrieval path) and
[Reader/doc/developer/README.md](../Reader/doc/developer/README.md).
Filesystem, execution, patch, TSV and clock capabilities are documented by
[Workspace](../Workspace/README.md):
[Workspace/doc/user/SandboxAndOutputs.md](../Workspace/doc/user/SandboxAndOutputs.md)
(sandbox semantics, output handling) and
[Workspace/doc/user/TSV.md](../Workspace/doc/user/TSV.md) (the authoritative
TSV reference).

**Capability mapping (all 36 registered tasks).**

| Family | ComputerUse tasks | Successor / status |
|---|---|---|
| Filesystem (9) | `write`, `read`, `list_directory`, `file_stats`, `pwd`, `copy`, `delete`, `search`, `sandbox_paths` | Workspace — same tasks registered there |
| Execution (4) | `bash`, `python`, `ruby`, `r` | Workspace |
| Patch (1) | `patch` | Workspace (Workspace additionally has `precise_edit`, never registered here) |
| TSV (8) | `tsv_info`, `tsv_read`, `tsv_query`, `tsv_edit`, `tsv_merge`, `tsv_attach`, `tsv_translate`, `tsv_sort` | Workspace — [Workspace/doc/user/TSV.md](../Workspace/doc/user/TSV.md) |
| Clock (1) | `current_time` | Workspace (registered on both; Workspace is the maintained home) |
| Document/web acquisition (11) | `searxng`, `docx2md`, `html2md`, `html_query`, `pdf2md`, `pdf2md_full`, `pdf2md_no_images`, `excerpts`, `rag`, `query`, `pdf_query` | Reader — same 11 tasks registered there; of them `searxng`, `docx2md`, `html2md`, `html_query` are agent-exposed, the seven retrieval/conversion tasks CLI/programmatic |
| KnowledgeBase registration (1) | `kb_register` | **No successor; remains only in deprecated ComputerUse pending migration decision** — not active tooling |
| Browser end-to-end tests (1) | `playwright` | **No successor; remains only in deprecated ComputerUse pending migration decision** — not active tooling |

23 tasks map to Workspace, 11 to Reader, 2 are unresolved — 36 in total,
matching the registered-task set of the exposure audit.

**Unresolved capabilities.** `kb_register` (TSV-backed association-database
registration in a Scout KnowledgeBase) and `playwright` (Playwright browser
tests) were registered on ComputerUse only; no successor registration
exists anywhere. No successor; they remain only in deprecated ComputerUse
pending a migration decision, and must not be presented as active tooling.
Their operational material is preserved, unchanged, under
[doc/deprecated/Tasks.md](doc/deprecated/Tasks.md).

**Historical material.** All 36 task entries
([doc/deprecated/Tasks.md](doc/deprecated/Tasks.md)), the former user and
developer pages
([doc/deprecated/user/](doc/deprecated/user/),
[doc/deprecated/developer/](doc/deprecated/developer/)) and the two retired
skills ([doc/deprecated/skills/](doc/deprecated/skills/)) are preserved
verbatim, each file headed by a deprecation banner. Everything under
ComputerUse/doc/ is deprecated; nothing in this repo is maintained
documentation.
