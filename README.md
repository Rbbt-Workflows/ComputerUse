Agent-friendly utilities for document conversion, filesystem/process helpers, patch application, Playwright testing, and simple web search.

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

## patch
Apply a patch to repository files with auto-detected strip, canonical ChatGPT conversion, and optional direct-apply fallback

This task accepts textual patch content and applies it using the system patch utility from the repository root. It is designed for AI agents that produce ChatGPT-style patch blocks and handles them robustly:
- Converts ChatGPT markers (*** Begin/End Patch; *** Update/Add/Delete File: path) into a canonical unified diff with a/ and b/ headers
- Synthesizes @@ headers when missing and ensures a trailing newline
- Auto-detects the correct -p (strip) level by trying -p0..-p4 with --dry-run (when strip is not provided)
- Returns structured diagnostics including the generated patch text and all tried -p attempts
- Optional apply_direct fallback that writes full-content updates/additions directly if patch cannot be applied (with backups)

Inputs
- patch (required): Patch content (unified diff or ChatGPT-style)
- strip: Integer -pN. If omitted, auto-detects via --dry-run
- dry_run: Boolean. If true, checks only; does not modify files
- apply_direct: Boolean. If true, when patch application fails and the patch appears to be full file content, write files directly (backups made)

Outputs
- JSON with:
  - stdout, stderr, exit_status
  - generated_patch (canonical unified diff we produced)
  - used_strip (integer or null)
  - tried_strips ([{strip, stdout, stderr, exit_status}])
  - applied (boolean)
  - applied_directly (boolean)
  - suggestion (string)

Examples
- Dry-run a ChatGPT-style patch and inspect the generated unified diff
```ruby
patch_text = <<~PATCH
*** Begin Patch
*** Add File: lib/example.rb
puts 'hi'
*** End Patch
PATCH
res = ComputerUse.job(:patch, patch: patch_text, dry_run: true).run
info = JSON.parse(res.stdout)
puts info["generated_patch"]
# => --- /dev/null
#    +++ b/lib/example.rb
#    @@ -0,0 +1,1 @@
#    +puts 'hi'
```

- Apply after a successful dry-run (auto-detects -p)
```ruby
ComputerUse.job(:patch, patch: patch_text, dry_run: false).run
```

- Force apply_direct fallback for full-content updates
```ruby
update_text = <<~PATCH
*** Begin Patch
*** Update File: lib/example.rb
puts 'updated'
*** End Patch
PATCH
# Force a bad strip to trigger fallback; set apply_direct: true
res = ComputerUse.job(:patch, patch: update_text, strip: 99, apply_direct: true, dry_run: false).run
info = JSON.parse(res.stdout)
puts info["applied_directly"] # => true (when full-content update)
```

Notes
- All paths are validated and must remain under ComputerUse.root (".." is disallowed). Absolute paths are normalized against the root when possible.
- When apply_direct is used, existing files are backed up to .bak.<timestamp> and writes are atomic (tmp file then rename).

## brave
Web search using Brave Search API

Query the Brave Search API to obtain web search results. Requires BRAVE_API_KEY to be set.

Inputs
- query (required): search string

Outputs
- Array of {url, text}

## playwright
Run Playwright test code or file against a URL

Accepts inline Playwright test code (JS/TS) or a path to an existing test file and runs it using npx playwright test inside the workflow sandbox. Reports and artifacts are written to:
- .playwright/scripts (generated test files)
- .playwright/runs (json report, html report, traces, videos)

Outputs
- JSON with stdout, stderr, exit_status and artifact paths
