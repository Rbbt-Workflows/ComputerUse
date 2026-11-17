RETIRED — this skill is deprecated with the ComputerUse workflow and no
longer lives under ComputerUse/skills/ (that directory is now empty);
preserved here for reference. The frontmatter below is inert: the banner
is intentionally placed above it. See ComputerUse/README.md for the
deprecation notice and successor pointers.

---
name: computeruse-playwright
description: Run Playwright browser tests through the ComputerUse playwright task - pass inline test code or a spec file, control headless/trace/video/timeout, and find run artifacts. Use when an agent must exercise a web UI end-to-end (visit a URL, click through flows, assert on rendered state) as part of a bout instead of hand-rolling a browser session. Triggers: playwright, browser test, "end-to-end", headless, trace, video recording, ".playwright/runs", "npx playwright".
---

# ComputerUse Playwright browser tests

## What this skill covers

Running browser end-to-end tests with the `playwright` task — the one
ComputerUse-unique task in the GUI automation family. It wraps `npx playwright`
(installed project-wide): it materializes a Playwright spec (inline code or an
existing file), runs it against a target URL, and returns the run's JSON
report. Use it when a claim requires interacting with a real browser (click
flows, rendered DOM, screenshots/video) rather than fetching HTML with
`html2md`.

## Inputs and their defaults

| Input | Type | Default | Meaning |
|---|---|---|---|
| `url` | string | required | URL the test should visit (e.g. http://localhost:3000) |
| `code` | text | nil | Playwright test code (JS/TS); saved under `.playwright/scripts` and executed |
| `file` | path | nil | Existing Playwright test file; used instead of inline `code` |
| `headless` | boolean | true | Run browser headlessly |
| `trace` | boolean | false | Enable Playwright tracing for the run |
| `video` | boolean | false | Enable video recording for tests |
| `timeout` | integer | 10 | Per-test timeout in seconds |
| `extra_args` | string | '' | Extra arguments passed to `playwright test` |

Provide exactly one of `code` or `file` (with `url` always required).

## Artifacts and where they land

- Inline code is written to `.playwright/scripts/` under the process working
  directory.
- Each run gets a timestamped directory under `.playwright/runs/`
  (`<timestamp>_<pid>_<rand>`); traces and videos land there when enabled.
- The task returns the run report as JSON.

Check `.playwright/runs/<timestamp>/` for artifacts when a test fails — the
JSON result says the run happened, not why the browser disagreed.

## Working practice

- Write the smallest spec that answers the question under test (visit page,
  assert one thing) rather than porting a whole suite; the task is for
  bounded verification inside a bout.
- Prefer `headless: true` (the default) — a headed run is only useful when a
  human will watch it.
- Enable `trace` when a failure is not explained by the report; the trace can
  be replayed afterwards.
- The task runs from the process working directory; make sure the target URL
  is reachable from the sandbox (see
  [doc/user/README.md](../../user/README.md) for the sandbox model and
  [Workspace/doc/user/SandboxAndOutputs.md](../../../../Workspace/doc/user/SandboxAndOutputs.md)
  for the shared execution semantics).

## Where to read more

- The `## playwright` entry in ComputerUse/README.md for the task contract.
- [doc/developer/README.md](../../developer/README.md) for the npx
  playwright dependency and the export surface.
