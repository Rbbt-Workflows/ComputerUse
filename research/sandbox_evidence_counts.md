# Sandbox confusion evidence — raw counts from recent chats

Scanned (current date: 2026-08-25 07:04 CEST; window = last 48h):

| Chat file | mtime | read_denied | write_denied | other notable errors |
|---|---|---|---|---|
| ~/git/scout-gear/chats/doc_learning_chat_analyst | Aug 24 18:54 | 3 (~/chats, /home/mvazque2/git, /bulk/mvazque2/git/scout-ai) | 0 | 2x "Too many files" (7569>200); 2x chat_tool_calls truncation (>100k) |
| ~/chats/ChatAnalyst/improve_after_doc (4.1MB) | Aug 25 02:23 | 1 (.rvm gems scout-ai lib) | 0 | 16x "boom" (test); "Too many files 152>30"; "Not a directory ./workflow.rb"; chat_tool_calls truncation; "Chat or job not found ~/chats/doc_learning" |
| ~/git/scout-gear/chats/doc_learning | Aug 24 10:11 | 0 | 0 | chat_agents truncation only |
| ~/chats/Cortex/develop | Aug 25 07:04 | 0 | 0 | - |
| ~/chats/Cortex/EvolveCortex.md | Aug 24 20:42 | 0 | 0 | - |
| ~/chats/Cortex/test | Aug 24 20:36 | 0 | 0 | - |

Denial messages include the full allowlist (from filesystem.rb normalize rescue), e.g.:
["/bulk/mvazque2/git/scout-gear", ".../tmp", "/home/mvazque2/.scout/tmp", "/home/mvazque2/tmp/scout", "/bulk/mvazque2/git/scout-ai/tmp", "/bulk/mvazque2/git/scout-essentials/tmp", "/bulk/mvazque2/git/workflows/ComputerUse/tmp", "/tmp", "/home/mvazque2/tmp", "/bin", "/usr", "/lib", "/lib64", "/etc"]

Key confusion episodes in doc_learning_chat_analyst:
1. Agent asked to inspect ~/chats/doc_learning -> chat_report/chat_overview "Chat or job not found"; list_directory "~/chats" DENIED (allowlist). pwd shows /bulk/.../scout-gear. Agent guessed paths (/bulk/.../scout-ai DENIED too).
2. Agent discovered via vim swap file that real file lived at ~/chats/scout-gear/doc_learning_chat_analyst (i.e. /home/mvazque2/chats/...), a path it could not read with ComputerUse tasks but ChatAnalyst tasks COULD (different allowlist).
3. bash vs list_directory asymmetry: `bash` (bwrap) could traverse some paths denied to list_directory (e.g. .rvm, .scout, chats mounted ro), and bwrap itself can FAIL with "Process ... failed" (exit -1) when a command references an unmounted path (e.g. /home/mvazque2/chats/ChatAnalyst/improve_after_doc in this very session).

Live sandbox facts (this session):
- pwd = /bulk/mvazque2/git/workflows/ComputerUse
- /proc/mounts (inside sandbox) shows the bwrap plan: ro-bind: /home/mvazque2/.rvm, /home/mvazque2/.scout, /home/mvazque2/chats, /home/mvazque2/git (/dev/sdc1 via /bulk/mvazque2/git), /bulk/mvazque2/git/workflows, /home/mvazque2/.rbbt/workflows, micromamba envs, config/etc/AI, plus /usr,/bin,/lib,/etc; rw-bind: /tmp, /home/mvazque2/tmp (-> /fast/mvazque2/tmp!), /home/mvazque2/.rbbt/tmp (-> /bulk/mvazque2/rbbt/tmp), /home/mvazque2/.scout/tmp, /home/mvazque2/.scout/var, repo tmp dirs, ComputerUse root, per-job chat files.
- NOT mounted: /home/mvazque2/chats is ro but NOT in the Ruby-level read allowlist (so list_directory denies it even though bash can read it); /home/mvazque2/.rbbt/var (only specific job files are ro-bound, individually!).
- Symlink/mount mapping quirk: ~/.rbbt -> /home/mvazque2/.rbbt real dir (not symlink) but with submounts; ~/.scout/chats -> /home/mvazque2/chats (symlink); ~/tmp is writable because /fast/mvazque2/tmp is bind-mounted onto /home/mvazque2/tmp.
