Agent-friendly utilities for document conversion, filesystem helpers, patch, Playwright testing, etc. 

This workflow exposes tasks that are useful for AI agents operating over a codebase or dataset: converting PDFs/HTML to Markdown, listing/reading/writing files, running bash/Python/Ruby/R, applying patches (including ChatGPT-style patches) safely, and running Playwright tests. All tasks integrate with the Scout/Rbbt workflow model (typed inputs/outputs, caching, provenance, and CLI integration). You can call them programmatically from other workflows or via the workflow runner.

Dependencies and environment
- Ruby and the Scout/Rbbt environment (the workflow extends Workflow)
- Optional CLIs depending on tasks:
  - docling CLI for PDF → Markdown
  - html2markdown CLI for HTML → Markdown
  - npx playwright for Playwright tests (installed project-wide)
- The tasks rely on Scout helpers like CMD and Open and use a sandbox (bwrap) when available for safer execution.

Notes on outputs
- Document conversion tasks return Markdown text or produce Markdown files under the task temporary area.
- The patch task returns a structured JSON result (stdout, stderr, exit_status, generated_patch, used_strip, tried_strips, applied flags).
- Exec tasks (bash/python/ruby/r) return stdout, stderr and exit status as JSON.

A note on etiquette for AI agents: If you are going to be generating files with
data and scripts to perform tasks or test developments, please consider writing
them on a directory like './tmp', './results', or './sandbox'. Also keep in
mind that you will most likely only have read, write, and list access to files
and directories inside the current working directory. Likewise, you may find
the executions of bash, python, ruby, or R scripts sandbox that will provide
read access across the system, but write access only under the current
directory and some other directories like '/tmp', '~/.rbbt/tmp', '~/.rbbt/var',
'~/.scout/tmp', and '~/.scout/var'. Take this in considerations if programs
fail to create temporary files on other locations and consider if these
software elements can be pointed to a different location for temporary and
cache files, perhaps using environmental variables.

# Tasks

## current_time
Return current time as string

Returns the current system time formatted by Ruby's Time.now.to_s. Exported for direct execution (export_exec :current_time). Takes no inputs and returns a plain string for quick checks.

Example
```
ComputerUse.current_time # => "2026-02-03 11:00:00 +0000"
```

## pdf2md_full
Convert a PDF file to Markdown using docling

Runs docling on the provided PDF and writes the produced Markdown in the task files directory. The first generated file is moved to the task temporary path so it is the step's primary file.

Inputs
- pdf (required): path to the PDF file

Outputs
- A :md file written under the step area

Notes
- Requires docling in PATH.

## pdf2md_no_images
Convert a PDF to Markdown and remove image lines

Depends on pdf2md_full and strips lines that start with "![Image]".

Notes
- This task is aliased as pdf2md.

## pdf2md
Alias to pdf2md_no_images

Use pdf2md when you want the image-stripped Markdown output.

## html2md
Convert HTML (or an HTML URL) to Markdown using html2markdown

Inputs
- html (required): either an HTML string or a remote URL

Outputs
- Markdown text produced by html2markdown

Notes
- For a URL, content is fetched via Open.open before conversion.

## excerpts
Split Markdown text into chunks (paragraphs/sentences/sliding windows)

Inputs
- text (required): Markdown text (or a Step pointing to markdown)
- strategy: paragraph | sentences | sliding (default: paragraph)
- chunk_words: integer (default: 50)
- overlap: integer (default: 10)

Behavior
- Splits the text and writes each excerpt to a file; returns ids array.

## rag
Create a RAG (retrieval-augmented generation) index from excerpts

Inputs
- embed_model: embedding model id (default: 'mxbai-embed-large')

Behavior
- Embeds excerpts via LLM.embed and saves an LLM::RAG index under tmp path.

## query
Search the RAG index for text matches

Inputs
- prompt (required): Text to match
- num: Number of matches (default: 3)

Outputs
- JSON array with best-matching excerpt texts.

## pdf_query
Query PDF-derived excerpts

Alias task that runs query with pdf2md as the text source.

## html_query
Query HTML-derived excerpts

Alias task that runs query with html2md as the text source.

## bash
Run a bash command

Execute an arbitrary bash command in a sandbox when available.

Inputs
- cmd (required): command string

Outputs
- JSON with stdout, stderr, exit_status

## python
Run Python code or file

Inputs
- code: Python code to run (ignored if file provided)
- file: Path to a Python file

Outputs
- JSON with stdout, stderr, exit_status

## ruby
Run Ruby code or file

Inputs
- code: Ruby code to run (ignored if file provided)
- file: Path to a Ruby file

Outputs
- JSON with stdout, stderr, exit_status

## r
Run R code or file

Inputs
- code: R code to run (ignored if file provided)
- file: Path to an R file

Outputs
- JSON with stdout, stderr, exit_status

## write
Write a file

Write content to a file under the workflow root. Paths are validated so targets must be under ComputerUse.root.

Inputs
- file (required): path under ComputerUse.root
- content (required): text to write

Outputs
- A short success message

## read
Read a file (head/tail or full)

Inputs
- file (required): Path to the file
- limit: Number of lines to return
- file_end: head | tail (default: head)
- start: Line offset (default: 0)

Outputs
- The requested file contents

## list_directory
List files and directories

Inputs
- directory (required): path under ComputerUse.root. Regular expression not allowed.
- recursive: boolean (default: true)
- stats: boolean (default: false)

Outputs
- JSON with files, directories (and optional stats)

## file_stats
Return basic stats about a file

Inputs
- file (required): path under ComputerUse.root

Outputs
- JSON with basic stats (type, size, lines, mtime)

## pwd
Return current working directory

Outputs
- String with the current working directory path

## playwright
Run Playwright test code or file against a URL

Accepts inline Playwright test code (JS/TS) or a path to an existing test file and runs it using npx playwright test inside the workflow sandbox. Reports and artifacts are written to:
- .playwright/scripts (generated test files)
- .playwright/runs (json report, html report, traces, videos)

Outputs
- JSON with stdout, stderr, exit_status and artifact paths

## patch
Apply a patch to repository files with auto-detected strip, canonical ChatGPT conversion, and optional direct-apply fallback

This task accepts textual patch content and applies it using the system patch utility from the repository root. It is designed for AI agents that produce ChatGPT-style patch blocks and handles them robustly:
- Converts ChatGPT markers (*** Begin/End Patch; *** Update/Add/Delete File: path) into a canonical unified diff with a/ and b/ headers
- Synthesizes @@ headers when missing and ensures a trailing newline
- Auto-detects the correct -p (strip) level by trying -p0..-p4 with --dry-run (when strip is not provided)
- Returns structured diagnostics including the generated patch text and all tried -p attempts
- Optional apply_direct fallback that writes full-content updates/additions directly if patch cannot be applied (with backups)

Important usage guidance
- Use patch ONLY for updating existing files. Do NOT use patch to add or delete files.
  - To add a file, use the write task.
  - To delete a file, use the delete task.
- Use dry-run after a few errors to confirm applicability and inspect diagnostics.
- Input formats supported:
  - ChatGPT-style blocks (recommended for agents):
    *** Begin Patch
    *** Update File: path/relative/to/root.ext
    <either a canonical unified diff hunk, or the full new file content>
    *** End Patch
  - Canonical unified diff (--- a/... +++ b/...) with @@ hunks
- Paths must be repo-root relative (no leading ./ or ../). Absolute paths are rejected or normalized.
- Ensure the patch text ends with a trailing newline.

CLI quick start (using scout)
- Dry run an update patch via stdin (note: only for updates, not adds/deletes):
  echo "*** Begin Patch
  *** Update File: tmp/patch_demo.txt
  -old
  +new
  *** End Patch" \
  | scout workflow task --exec --nocolor ComputerUse patch --patch - --dry_run

- Apply after a successful dry-run:
  echo "*** Begin Patch
  *** Update File: tmp/patch_demo.txt
  -old
  +new
  *** End Patch" \
  | scout workflow task --exec --nocolor ComputerUse patch --patch -

Diagnostics returned
- stdout, stderr, exit_status: raw outputs from the patch utility
- generated_patch: canonical diff the tool produced from your input
- used_strip: the -pN selected by auto-detection, or null if none worked
- tried_strips: array of {strip, stdout, stderr, exit_status} trials
- applied: whether the patch was applied (false on dry_run)
- applied_directly: whether direct-write fallback was used (see caution below)
- suggestion: human-readable guidance

Common pitfalls and fixes
- Patch content contains code fences (``` ... ```): strip fences before submission.
- Missing diff headers: use ChatGPT-style Update File block or a canonical unified diff.
- Paths have leading ./ or are absolute: provide clean, root-relative paths.
- No trailing newline: add one to the patch text.
- Wrong strip level: auto-detect tries 1,0,2,3,4; if it fails, specify strip explicitly.
- Trying to add/delete via patch: use write/delete tasks instead.

Caution on apply_direct
- apply_direct writes full-file "plain content" updates directly when the diff cannot be applied and the input looks like a full replacement. It makes timestamped backups before overwriting.
- Prefer using patch (diff) for updates; reserve apply_direct for last-resort plain-content updates. Do not rely on apply_direct for creating or removing files—use write/delete tasks instead.

Inputs
- patch (required): Patch content (unified diff or ChatGPT-style)
- strip: Integer -pN. If omitted, auto-detects via --dry-run
- dry_run: Boolean. If true, checks only; does not modify files
- apply_direct: Boolean. If true, when patch diffing fails and the block looks like a full-file replacement, write the file directly (with backups)

Outputs
- JSON with:
  - stdout, stderr, exit_status
  - generated_patch (canonical unified diff we produced)
  - used_strip (integer or null)
  - tried_strips ([{strip, stdout, stderr, exit_status}])
  - applied (boolean)
  - applied_directly (boolean)
  - suggestion (string)

Notes
- To add and remove entire files please use write and delete tasks, not patch.
- All paths are validated and must remain under the root (current directory of the process) (".." is disallowed). Absolute paths are normalized against the root when possible.
- When apply_direct is used, existing files are backed up to .bak.<timestamp> and writes are atomic (tmp file then rename).

## brave
Web search using Brave Search API

Query the Brave Search API to obtain web search results. Requires BRAVE_API_KEY to be set.

Inputs
- query (required): search string

Outputs
- Array of {url, text}
