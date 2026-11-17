RETIRED — this skill is deprecated with the ComputerUse workflow and no
longer lives under ComputerUse/skills/ (that directory is now empty);
preserved here for reference. The frontmatter below is inert: the banner
is intentionally placed above it. See ComputerUse/README.md for the
deprecation notice and successor pointers.

---
name: computeruse-doc-conversion
description: Convert and acquire documents from the ComputerUse side - PDF, DOCX, HTML and web search to Markdown, retrieval over converted text, and registering association databases in a Scout KnowledgeBase. Use when an agent works through the ComputerUse tool surface (tool: ComputerUse) rather than Reader, needs to choose between conversion and targeted retrieval, or must register a TSV association database with kb_register. Triggers: pdf2md, pdf2md_full, pdf2md_no_images, docx2md, html2md, searxng, excerpts, rag, query, pdf_query, html_query, kb_register, "convert PDF", "convert DOCX", "convert HTML", "web search", "knowledge base", "association database".
---

# ComputerUse document conversion and KnowledgeBase registration

## What this skill covers

Choosing the right ComputerUse task when converting or acquiring documents,
deciding between whole-document conversion and targeted retrieval, and
registering TSV association databases in a Scout KnowledgeBase. It is the
ComputerUse-side view of a task family that is **co-registered with Reader**:
the 11 document/web tasks (`searxng`, `docx2md`, `pdf2md`, `pdf2md_full`,
`pdf2md_no_images`, `html2md`, `excerpts`, `rag`, `query`, `pdf_query`,
`html_query`) are the same tasks registered on Reader, which owns the
maintained documentation of the family (Reader/doc/user/README.md and the
`reader-doc-acquisition` skill). Only `kb_register` is ComputerUse-unique.

This skill does not cover the filesystem/exec/TSV families — those are shared
with Workspace and covered by the `workspace-files`, `workspace-execution` skills (TSV reference: Workspace/doc/user/TSV.md).

## Which task for which source

| Source | Conversion | With retrieval | Requirement |
|---|---|---|---|
| Web search | `searxng` (JSON results) | — | SearXNG instance (`SEARXNG_URL` or `searxng_url`) |
| HTML text or URL | `html2md` | `html_query` | html2markdown CLI |
| PDF | `pdf2md` / `pdf2md_full` / `pdf2md_no_images` | `pdf_query` | docling CLI |
| DOCX | `docx2md` | — | Pandoc |

PDF variants: `pdf2md_full` runs docling and promotes the first generated
file to the step's primary file; `pdf2md_no_images` is `pdf2md_full` plus
stripping of `![Image]` lines; `pdf2md` composes the same pipeline. Use
`_no_images` when image markers would pollute downstream text processing.

## Convert-then-think vs targeted retrieval

Whole-document conversion (the `*2md` tasks) is for when you need the full
text as an artifact — to persist, to search yourself, or to feed other tools.
Targeted retrieval is for answering questions against a document without
materializing the whole thing in context:

- `excerpts` — split Markdown text into `rbbt-text` segments.
- `rag` — build the embedding index for those segments.
- `query` — search the index with a prompt; build the excerpt and RAG
  dependencies inline from `text`.
- `pdf_query` / `html_query` — one-shot composites: convert the document and
  run the same retrieval path over the result.

Prefer `pdf_query`/`html_query` over manually chaining `pdf2md` → `query`;
prefer conversion-then-`excerpts`/`rag`/`query` only when you will issue
several queries against the same document (the index is then reused rather
than rebuilt per query).

## Registering an association database: kb_register

`kb_register` stores a TSV-backed association database in Scout's KnowledgeBase
registry using `KnowledgeBase#register`/`#save`. Required inputs: `name`
(simple database name), `source_file` (association TSV, readable under the
ComputerUse sandbox policy), `source` and `target` (key-field specifications,
which may use Scout entity/field syntax). Optional: `knowledge_base`
(`current` default, `:default`, a workflow name, or an explicit path),
`fields`, `undirected`, `identifiers`, `namespace`, `description`.

Behavior worth knowing before calling it:

- The source TSV must already be in Scout association shape; normalize first
  with `tsv_info`/`tsv_read` (maintained reference: Workspace/doc/user/TSV.md).
- The task registers metadata and the TSV path; it does not copy or rewrite
  the source file.
- Write permissions at the destination are validated before the registry
  changes; the result is JSON describing the KnowledgeBase location,
  registered database name, and available databases.
- Registration does not validate every row's semantics — query or open the
  database through Scout to verify the usable association index.

## Where to read more

- README task entries (`## kb_register`, `## searxng`, `## docx2md`, the PDF
  and retrieval entries) for exact inputs and error behavior.
- [doc/user/README.md](../../user/README.md) — duplication map (which
  tasks also live on Reader/Workspace) and sandbox differences.
- [doc/developer/README.md](../../developer/README.md) — external
  dependency table (docling, html2markdown, Pandoc, SearXNG) and the export
  surface (which of these tasks are exposed as agent tools).
