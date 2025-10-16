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
- Uses CMD.cmd(:docling, "#{pdf} --output #{self.files_dir}") to invoke docling.
- Uses Open.mv file(files.first), self.tmp_path to move the first generated file into the task temporary path.

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
- This task is aliased as pdf2md (task_alias :pdf2md, ComputerUse, :pdf2md_no_images), so users can call pdf2md as the image-stripped converter.
- If you want image references preserved, run pdf2md_full directly (exported as pdf2md_full).

## pdf2md
Alias to pdf2md


## html2md
Convert HTML (or an HTML URL) to Markdown using html2markdown

Takes a required input html which may be either raw HTML text or a URL pointing to an HTML document. If the input appears to be a remote URL, the task fetches the content via Open.open. It then invokes the html2markdown CLI by passing the HTML content to the command (CMD.cmd(:html2markdown, in: html)) and returns the Markdown output as text.

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

End of README.md
