Convert documents (PDF/HTML) into Markdown and a simple helper that returns the current time.

This workflow exposes lightweight tasks for converting PDFs to Markdown (with or without embedded image markers) and for converting HTML (or HTML URLs) to Markdown. It relies on external command-line tools to perform conversions: docling for PDF → Markdown and html2markdown for HTML → Markdown. Tasks are written to integrate with the Scout task model (inputs/outputs, dependencies, exported tasks). Typical uses: programmatic invocation from other Scout workflows or running exported tasks directly. Make sure you have the Scout/Rbbt environment and the required external CLIs installed and available in PATH.

Dependencies and environment
- Ruby and the Scout/Rbbt environment (the workflow uses `require 'scout'` and extends Workflow).
- docling CLI available in PATH for PDF → Markdown conversion.
- html2markdown CLI available in PATH for HTML → Markdown conversion.
- The workflow uses Scout helpers like CMD, Open, and file management methods from the workflow base.
- The workflow exports tasks so they can be executed from other code/modules or via the workflow runner.

Notes on outputs
- pdf2md_full: uses docling to produce Markdown files in the task's files directory and moves the primary generated file to the task temporary path. The task is marked with extension :md.
- pdf2md_no_images: reads the markdown produced by pdf2md_full and strips lines that start with the image placeholder "![Image]".
- pdf2md: (aliased as pdf2md_no_images)
- html2md: runs html2markdown with the HTML content (or with the content fetched from a URL) and returns the Markdown output.
- current_time: returns a string with the current timestamp. This task is exported for direct execution.

# Tasks

## current_time
Return current time as string

Returns the current system time formatted by Ruby's Time.now.to_s. This is exported for direct execution (export_exec :current_time). It takes no inputs and returns a plain string suitable for quick checks, logging, or simple example usage.

Example usage:
- Executing the exported task will return the current timestamp as text.

Implementation notes:
- Implemented as a simple Scout task that returns Time.now.to_s.

## pdf2md_full
Convert a PDF file to Markdown using docling

This task accepts a single required input named pdf (a file path to the PDF). It runs the external docling command, instructing it to write its output files into the task's files directory (self.files_dir). After docling produces its output files, the task moves the first generated file into the task temporary path (self.tmp_path) so the produced Markdown is available as the task's primary file. The task is declared with extension :md and is intended to produce Markdown output that may include image placeholders or links depending on docling's behavior.

Inputs
- pdf (required): path to the PDF file to convert.

Outputs
- Primary markdown file written to the task's file area (and moved to tmp_path). The task itself returns nil, but the produced file exists as the task output and has :md extension.

Implementation details
- Uses the docling CLI and directs output to the task files dir.
- Raises a ScoutException if docling fails or produces no output.

Requirements and notes
- docling must be installed and accessible in PATH.
- The task expects docling to write at least one output file into the specified output folder. If docling behavior changes, adjustments may be needed.

## pdf2md_no_images
Convert a PDF to Markdown and remove image lines

This task depends on pdf2md_full and post-processes the markdown produced by that task to strip out lines that begin with the string "![Image]". The intent is to remove image placeholders or automatically inserted image markers from the markdown output when images are not needed. The task is declared with extension :md and returns the filtered markdown text.

Behavior
- Loads the markdown text produced by the pdf2md_full dependency.
- Splits the text by newlines and discards any line that starts with "![Image]".
- Rejoins and returns the filtered text as the task result.

Notes
- This task is aliased as pdf2md, so users can call pdf2md as the image-stripped converter.
- If you want image references preserved, run pdf2md_full directly (exported as pdf2md_full).

## pdf2md
Alias to pdf2md_no_images

A convenience alias that invokes pdf2md_no_images. Use pdf2md when you want the image-stripped Markdown output.

## html2md
Convert HTML (or an HTML URL) to Markdown using html2markdown

Takes a required input html which may be either raw HTML text or a URL pointing to an HTML document. If the input appears to be a remote URL, the task fetches the content via Open.open. It then invokes the html2markdown CLI by passing the HTML content to the command and returns the Markdown output as text.

Inputs
- html (required): either an HTML string or a URL pointing to an HTML page.

Outputs
- Markdown text produced by html2markdown.

Implementation details
- Uses Open.open(html) to fetch content when the input is detected as remote (Open.remote?(html)).
- Requires html2markdown to be installed and available in PATH.

Usage examples and tips
- For a remote URL, provide the URL string and the task will fetch and convert it.
- For local HTML content, supply the raw HTML string.

## excerpts
Split Markdown text into chunks (paragraphs/sentences/sliding windows)

This task takes a Markdown text input and splits it into smaller excerpts according to a selected chunking strategy. It supports three strategies: paragraph, sentences, and sliding. The task writes each excerpt to a file and returns an array of identifiers for the stored excerpts.

Inputs
- text (required): Text in Markdown or a Step pointing to a Markdown resource.
- strategy: one of paragraph, sentences or sliding (default: paragraph).
- chunk_words: integer controlling approximate words per chunk when splitting (default: 50).
- overlap: number of words of overlap for sliding window or paragraph splitting (default: 10).

Behavior and details
- paragraph: splits on blank lines, filters short paragraphs, and further splits long paragraphs into chunks of ~chunk_words with overlap.
- sliding: produces a sliding window over words producing chunks of chunk_words with overlap.
- sentences: groups sentences until approximately chunk_words is reached using a naive sentence split.
- The task deduplicates near-identical excerpts, trims them, writes each excerpt to a file via Misc.digest-based ids, and returns the ids array.

## rag
Create a RAG (retrieval-augmented generation) index from excerpts

This task depends on excerpts and creates embeddings for each excerpt using the configured LLM embedder. It creates a RAG index and saves it to the task temporary path. The saved index extension is :rag.

Inputs
- embed_model: embedding model identifier (default: 'mxbai-embed-large').

Behavior
- Loads excerpt ids from the excerpts step, reads the corresponding files, obtains embeddings via LLM.embed, and builds an LLM::RAG index.
- Saves the index to the task's temporary path for later loading by query.

Requirements
- The workflow expects the Scout LLM helpers (LLM.embed and LLM::RAG) to be available.

## query
Search the RAG index for text matches

This task depends on the excerpts and rag steps. Given a prompt, it embeds the prompt using the same embedding model and performs a k-NN search against the saved RAG index, returning the matching excerpt texts.

Inputs
- prompt (required): Text to match.
- num: Number of matches to return (default: 3).

Outputs
- JSON array of the best-matching excerpt texts.

Behavior and details
- Uses the embed_model from recursive inputs to embed the prompt.
- Loads the saved RAG index from the rag step and performs search_knn to get indices and scores.
- Returns the excerpts corresponding to the top indices and sets step info with scores.

## pdf_query
Query PDF-derived excerpts

Alias task that runs query using pdf2md (the pdf2md task output) as the text source. Use pdf_query to search content extracted from a PDF.

## html_query
Query HTML-derived excerpts

Alias task that runs query using html2md (the html2md task output) as the text source. Use html_query to search content extracted from HTML.

## bash
Run a bash command

Execute an arbitrary bash command. Returns a JSON-like object containing stdout, stderr and exit_status. The command is run through the workflow's sandboxing/cmd_json helper which attempts to use bwrap for isolation and will fall back to running unsandboxed if bwrap is not available.

Inputs
- cmd (required): Bash command string to run.

Outputs
- JSON object with keys stdout, stderr and exit_status.

Notes
- Sandboxing is attempted via bwrap if available; otherwise the task warns and runs unsandboxed.

## python
Run Python code or file

Execute Python code or run a Python file. If code is provided (and no file), the task writes it to a temporary script in the task root and runs it. The task tries to prefer python3 if available. Returns stdout, stderr and exit_status.

Inputs
- code: Python code to run (ignored if file provided).
- file: Path to a Python file to execute.

Outputs
- JSON object with keys stdout, stderr and exit_status.

Notes
- The command is run via cmd_json and sandbox_run, so the same bwrap behavior applies.

## ruby
Run Ruby code or file

Execute Ruby code or run a Ruby file. If code is provided (and no file), the task writes it to a temporary script in the task root and runs it. Returns stdout, stderr and exit_status.

Inputs
- code: Ruby code to run (ignored if file provided).
- file: Path to a Ruby file to execute.

Outputs
- JSON object with keys stdout, stderr and exit_status.

## r
Run R code or file

Execute R code or run an R file. If code is provided (and no file), the task writes it to a temporary script in the task root and runs it. The task prefers Rscript when available and will use R with suitable flags as fallback. Returns stdout, stderr and exit_status.

Inputs
- code: R code to run (ignored if file provided).
- file: Path to an R file to execute.

Outputs
- JSON object with keys stdout, stderr and exit_status.

## write
Write a file

Write content to a file under the workflow root. Paths are normalized and validated so the target must be under ComputerUse.root. Returns a success message on completion.

Inputs
- file (required): File path to write (must be under ComputerUse.root).
- content (required): Content to write into the file.

Outputs
- A short success string acknowledging the write.

## read
Read a file (head/tail or full)

Read the contents of a file. By default the task returns the entire file. Optionally you can specify a limit and file_end (head or tail) and a start offset to return a slice of lines efficiently without loading the whole file.

Inputs
- file (required): Path to the file to read.
- limit: Number of lines to return from chosen end of the file.
- file_end: head or tail (default: head).
- start: Line offset (default: 0).

Outputs
- The requested file contents (string).

Notes
- The task will raise an error if the path is not under ComputerUse.root or if file not found.

## list_directory
List files and directories

List the files and directories contained in a directory, optionally recursively, and optionally returning basic stats (size and mtime). Returns a JSON object with keys files, directories and, when requested, stats.

Inputs
- directory (required): Directory to list (must be under ComputerUse.root).
- recursive: boolean controlling recursion (default: true).
- stats: boolean to include file stats (default: false).

Outputs
- JSON object describing files, directories (and optional stats).

## file_stats
Return basic stats about a file

Return basic stats for a given file path including type (file or directory), size, number of lines and modification time. Returns a JSON object.

Inputs
- file (required): File path to examine.

Outputs
- JSON object with file stats.

## pwd
Return current working directory

Return the current process working directory (PWD). This is an exported helper task useful when invoking the workflow from other contexts.

Outputs
- String with the current working directory path.

## patch
Apply a patch to repository files using the patch utility

Accepts textual patch content and applies it using the system patch command. The helper includes logic to convert ChatGPT-style patch blocks ("*** Update File: ..." and "*** Begin Patch" markers) to a standard unified diff, and attempts to compute @@ hunk headers if they are missing. The task runs patch from the workflow root and supports a dry-run mode.

Inputs
- patch (required): Patch content (unified diff or ChatGPT-style patch content accepted).
- strip: integer for -pN (defaults to 0).
- dry_run: boolean, if true perform a dry-run (default: false).

Outputs
- JSON object with stdout, stderr and exit_status from the patch command.

Notes and warnings
- The patch task can modify repository files when not run with dry_run. Use with care and review output when applying changes.

## brave
Web search using Brave Search API

Query the Brave Search API to obtain web search results. The task returns an array of result objects containing url and text (title/description). Requires a BRAVE_API_KEY environment variable with a valid subscription token.

Inputs
- query (required): Search query string.

Outputs
- Array of objects {url: ..., text: ...} representing search results.

Requirements
- Set BRAVE_API_KEY environment variable to a valid Brave Search API key.

End of README.md
