# Design for the `sandbox_paths` task

## Where things live

- `workflow.rb` requires, in order: `lib/ComputerUse/exceptions.rb`,
  `lib/ComputerUse/tasks/filesystem.rb`, `lib/ComputerUse/tasks/exec.rb`, then
  patch/documents/playwright/web.
- `filesystem.rb` defines `ComputerUse.get_allowed_paths(type)`,
  `ComputerUse.allowed_paths` (writable), `ComputerUse.allowed_read_paths`
  (readable), helpers `inside?`/`normalize`, and the file tasks
  (`write/read/list_directory/file_stats/pwd/delete/copy/search`).
- `exec.rb` defines `Mount = Struct.new(:source, :destination, :mode,
  :requested_path)`, the helpers `plan_mounts(read_paths, writable_paths)` and
  `sandbox_run`, and the exec tasks (bash/python/ruby/r).
- Helpers are invoked as `ComputerUse.helper(:name, args...)` because they live
  in `Workflow.helpers` blocks evaluated in an anonymous module, not as module
  methods. Inside a `task ... do ... end` block, plain `helper_name` calls do
  work because the block is `instance_exec`ed on the step context which
  extends `step_module`.

## Config sources feeding the allowlists (from get_allowed_paths)

Type defaults, resolved in order (first match wins) via
`Scout::Config.get(type, :ComputerUse, :computer_use, :sandbox, env: TYPE)`:

- `allowed_paths` (writable): default `TMP_DIRS + ["/tmp", "~/tmp"]`; plus
  `dirs` key; plus `Thread.current['allowed_paths']` (populated per chat job by
  scout-ai `Chat.allow_path`, e.g. the job chat path, its `.info` and its
  `.files` dir).
- `allowed_read_paths`: no default (empty unless configured).
- `exec_paths` (readable): default `/bin:/usr:/lib:/lib64:/etc`.
- `read_paths` (readable): no default (empty unless configured).
- `thread` alias for writable thread paths; `thread_read` for readable ones.
- `bwrap_paths` / `bwrap_read_paths`: extra paths only for bwrap mounts, NOT
  visible to the Ruby-level `read/write/search` tasks.

`TMP_DIRS = Path.setup("tmp").find_all` = all `tmp` directories found on the
`$LOAD_PATH`/project search path, i.e. `/bulk/mvazque2/git/workflows/ComputerUse/tmp`,
`/home/mvazque2/.scout/tmp`, `/home/mvazque2/tmp/scout`, and the `tmp` dirs of
scout-ai, scout-gear, scout-essentials. This is why write access is granted to
several unrelated repos' tmp directories, and this is one of the documented
sources of confusion (agents see repo tmp dirs they did not expect in the
allowlist).

Layer 1 (Ruby check in `normalize`): root + writable + readable. If the path is
not under any of them, raises `SandboxAccessViolation` with the allowlist in
the message. Denials list raw allowlist entries with no ro/rw annotation,
which the plan says to fix.

Layer 2 (bwrap in `sandbox_run`): writable = allowed_paths + bwrap_paths +
per-call extras (e.g. `files_dir`) + `ComputerUse.root`; readable =
allowed_read_paths + exec_paths + read_paths + thread_read + bwrap_read_paths +
`/etc/resolv.conf` (if network) + runtime dirs of the executable + PATH
runtime dirs. `/tmp` always rw-bound; `--proc /proc`, `--dev /dev`; HOME and
PATH passed through; `--chdir` to `ComputerUse.root`.

## Task contract

`sandbox_paths` (no inputs, `:json`):

- header: `root` (`ComputerUse.root`), `pwd` (`Dir.pwd`), `home` (`ENV['HOME']`),
  `bwrap` (`find_bwrap`), `note` about layer-1 vs layer-2.
- `writable` and `readable` arrays: one entry per distinct expanded path with
  `path`, `origin` (symbol), `type` (directory/file/symlink/missing),
  `symlink` (bool), `readlink` (target when symlink), `realpath` (nil when
  missing), `exists` (bool).
- `mounts`: output of `plan_mounts(readable_paths, writable_paths)` mapped to
  `{source, destination, mode, requested_path, redirect}` where redirect is
  true when destination != requested_path (symlink redirection case).
- `realized_mounts`: parsed from `/proc/mounts` read directly by the workflow
  process (NOT via a sandboxed bash call, to avoid the bwrap exit -1 problem
  documented in the evidence file), only when `/proc/mounts` is readable;
  entries include `device, mountpoint, filesystem, options`, filtered to
  non-base entries.

## Why /proc/mounts is read directly

The evidence file `sandbox_evidence_counts.md` (already in the repo root)
documents that running a bwrap subprocess can fail with exit -1 when the
command references an unmounted path. Reading `/proc/mounts` with plain
`File.read` in-process is deterministic and shows exactly what the mounts are
for THIS process, which is what matters for the current workflow (when run
inside a chat, the workflow itself is the process whose mount table reflects
the orchestrator's sandbox, and when run via CLI it shows the host mounts).

## Notes on hidden coupling

- `export_exec` calls at the end of each task file register task names for
  tool exposure; new tasks should be added there in the same file.
- `start_chat` runs `exec_task: ComputerUse pwd` to show agents their working
  directory; the plan's advisory line update goes there.
- `README.md` documents tasks under `# Tasks` with `## name` sections; docs
  are generated from the workflow (there is a `doc` chat and the README
  matches the task list). I will add the section manually in the same style.
