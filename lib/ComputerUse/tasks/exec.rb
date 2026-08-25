module ComputerUse
  require 'open3'
  require 'tmpdir'

  # ===========================================================================
  # Mount struct — explicit representation of a single bind mount.
  #
  # +source+        Canonical host path (File.realpath of the requested path).
  # +destination+   Path visible inside the sandbox namespace.
  # +mode+          :ro (read-only) or :rw (read-write).
  # +requested_path+ The original expanded path requested by the caller.
  #
  # The critical invariant: destination is NOT derived from source via
  # realpath().  It is the path the application expects to use.
  # ===========================================================================
  Mount = Struct.new(:source, :destination, :mode, :requested_path, keyword_init: true)

  # ===========================================================================
  # Utility helpers
  # ===========================================================================

  # Compute the canonical realpath of a path, returning nil if the path
  # does not exist or cannot be resolved.
  helper :safe_realpath do |path|
    return nil if path.nil?
    File.realpath(path.to_s)
  rescue Errno::ENOENT, Errno::ENOTDIR, ArgumentError
    nil
  end

  # Lexical path-containment test: true if +child+ is the same as +parent+
  # or is a subdirectory of +parent+.  Uses "/" boundary to avoid false
  # positives like /foo matching /foobar.
  helper :path_under? do |child, parent|
    child == parent || child.start_with?(parent + "/")
  end

  # Map a mode symbol to the bwrap flag string.
  helper :mount_mode_flag do |mode|
    mode == :rw ? '--bind' : '--ro-bind'
  end

  # Walk every component of an expanded path from root downward and return
  # the first component that is a symlink on the host, or nil if none.
  #
  # Example: for /home/user/.rbbt/var/jobs where .rbbt/var is a symlink,
  # returns /home/user/.rbbt/var.
  helper :first_symlink_component do |path|
    path = File.expand_path(path.to_s)
    current = "/"
    path.split("/").reject(&:empty?).each do |part|
      current = File.join(current, part)
      return current if File.symlink?(current)
    end
    nil
  end

  # ===========================================================================
  # Mount planner — the core of the sandbox construction.
  #
  # Transforms requested read/write paths into a complete, validated,
  # ordered list of Mount objects.  The planner preserves both the
  # requested namespace (the path the application uses) and the canonical
  # namespace (File.realpath) so that symlinked paths resolve correctly
  # inside the sandbox.
  #
  # Pipeline stages:
  #   1. Create initial Mount objects from requested paths.
  #   2. Compute which destinations will be mounted.
  #   3. Adjust destinations that traverse symlinks whose parent is mounted.
  #   4. Add symlink dependency mounts (parent dirs + symlink targets).
  #   5. Semantic deduplication (same source+dest+mode = duplicate;
  #      child under same-or-broader-mode parent = redundant).
  #   6. Resolve read/write conflicts at the same destination.
  #   7. Sort by destination depth (parents before children).
  # ===========================================================================
  helper :plan_mounts do |read_paths, writable_paths|
    mounts = []

    # --- Phase 1: Create initial mount objects ---
    read_paths.each do |p|
      expanded = File.expand_path(p.to_s)
      next unless File.exist?(expanded)
      src = safe_realpath(expanded)
      next unless src
      mounts << Mount.new(source: src, destination: expanded, mode: :ro, requested_path: expanded)
    end

    writable_paths.each do |p|
      expanded = File.expand_path(p.to_s)
      #next unless File.exist?(expanded)
      src = safe_realpath(expanded)
      next unless src
      mounts << Mount.new(source: src, destination: expanded, mode: :rw, requested_path: expanded)
    end

    # --- Phase 2: Compute which destinations will be mounted ---
    # This is used to determine if a symlink's parent directory will be
    # present in the sandbox (which affects whether we can mount onto a
    # symlinked destination).
    all_destinations = mounts.map(&:destination)

    # --- Phase 3: Adjust destinations that traverse symlinks ---
    #
    # Key rule (experimentally verified):
    #   bwrap CANNOT mount onto a destination that is (or traverses) a
    #   symlink IF the symlink's parent is already mounted in the sandbox.
    #   When the parent IS mounted, the host symlink is visible in the
    #   namespace and bwrap's mount() call fails with ENOENT.
    #
    #   When the parent is NOT mounted, bwrap creates fresh directories
    #   at the destination, so mounting onto a symlinked path works fine.
    #
    # Therefore: if a mount's destination traverses a symlink AND the
    # symlink's parent is in the mount set, redirect the destination to
    # the canonical (realpath) location.
    mounts.each do |m|
      sym = first_symlink_component(m.destination)
      next unless sym

      parent_of_sym = File.dirname(sym)

      # Check if the symlink's parent (or an ancestor) is in the mount set.
      parent_mounted = all_destinations.any? do |d|
        path_under?(parent_of_sym, d)
      end

      if parent_mounted
        # Cannot mount onto the symlinked destination because the parent
        # is mounted, making the symlink visible.  Redirect to canonical.
        m.destination = m.source
      end
      # If parent is NOT mounted, keep the original destination — bwrap
      # will create fresh directories and there's no symlink conflict.
    end

    # --- Phase 4: Add symlink dependency mounts ---
    #
    # For mounts whose destinations were redirected (Phase 3), the
    # symlink from the parent mount needs its target to exist at the
    # canonical path so the symlink resolves inside the sandbox.
    #
    # Pattern (experimentally verified):
    #   --ro-bind /home/user/.rbbt     /home/user/.rbbt
    #   --ro-bind /bulk/user/rbbt/var  /bulk/user/rbbt/var
    #   → ls /home/user/.rbbt/var/jobs works because the symlink resolves.
    additional = []
    mounts.each do |m|
      sym = first_symlink_component(m.requested_path)
      next unless sym

      parent_of_sym = File.dirname(sym)
      target_of_sym = safe_realpath(sym)

      parent_mounted = all_destinations.any? do |d|
        path_under?(parent_of_sym, d)
      end

      if parent_mounted && target_of_sym
        # The symlink target must exist at its canonical path so the
        # symlink resolves.  Add a read-only mount for the target.
        already_covered = mounts.any? { |om| path_under?(target_of_sym, om.destination) }
        already_in_additional = additional.any? { |am| path_under?(target_of_sym, am.destination) }

        unless already_covered || already_in_additional
          additional << Mount.new(
            source: target_of_sym,
            destination: target_of_sym,
            mode: :ro,
            requested_path: target_of_sym
          )
        end
      end
    end
    mounts.concat(additional)

    # --- Phase 5: Semantic deduplication ---
    #
    # Two mounts are exact duplicates only if ALL of (source, destination,
    # mode) are identical.  Canonical source equality alone is NOT
    # sufficient — two paths resolving to the same host object but at
    # different sandbox destinations are NOT duplicates.
    #
    # A child mount is redundant (can be removed) if:
    #   - Its destination is under a parent mount's destination.
    #   - The parent has the SAME mode (ro parent + ro child, or rw parent + rw child).
    #     Different-mode children are NOT redundant: a rw child of a ro parent
    #     must remain to provide writable access, and a ro child of a rw parent
    #     must remain to restrict access.
    mounts = mounts.uniq { |m| [m.source, m.destination, m.mode] }

    mounts = mounts.reject do |candidate|
      mounts.any? do |other|
        next false if other.equal?(candidate)
        next false if candidate.destination == other.destination
        next false unless path_under?(candidate.destination, other.destination)

        if other.mode == candidate.mode
          # Same-mode parent covers same-mode child (redundant child).
          # ro parent covers ro child; rw parent covers rw child.
          true
        else
          # Different modes: child is NOT redundant.
          # ro parent does not cover rw child.
          # rw parent does not suppress ro child (ro child is intentional).
          false
        end
      end
    end

    # --- Phase 6: Resolve read/write conflicts at same destination ---
    #
    # If the same destination has both :ro and :rw mounts, keep only :rw.
    dest_modes = mounts.group_by(&:destination)
    mounts = mounts.reject do |m|
      siblings = dest_modes[m.destination]
      siblings.any? { |s| s.mode == :rw && m.mode == :ro }
    end

    # --- Phase 7: Sort by destination depth (parents before children) ---
    mounts.sort_by! { |m| [m.destination.count("/"), m.destination] }

    mounts
  end

  # ===========================================================================
  # Diagnostic logging — structured mount plan before bwrap execution.
  # ===========================================================================
  helper :log_mount_plan do |mounts|
    lines = ["SANDBOX MOUNT PLAN (#{mounts.length} mounts)"]
    mounts.each do |m|
      flag = mount_mode_flag(m.mode)
      tag = m.mode == :rw ? 'RW' : 'RO'
      if m.source == m.destination
        lines << "  #{tag}  #{m.destination}"
      else
        lines << "  #{tag}  #{m.source} -> #{m.destination}"
      end

      # Log symlink dependency info if the requested path differs from destination
      if m.requested_path != m.destination
        lines << "       (requested: #{m.requested_path})"
      end
    end
    Log.debug lines.join("\n")
  end

  # ===========================================================================
  # Validation — check the mount plan before bwrap execution.
  # ===========================================================================
  helper :validate_mount_plan do |mounts|
    mounts.each do |m|
      unless File.exist?(m.source)
        Log.warn "ComputerUse sandbox: mount source does not exist: #{m.source}"
      end
      unless m.source.to_s.start_with?("/")
        Log.warn "ComputerUse sandbox: mount source is not absolute: #{m.source}"
      end
      unless m.destination.to_s.start_with?("/")
        Log.warn "ComputerUse sandbox: mount destination is not absolute: #{m.destination}"
      end
    end

    # Check for destination conflicts (same dest, conflicting modes not resolved)
    dest_groups = mounts.group_by(&:destination)
    dest_groups.each do |dest, group|
      if group.length > 1
        Log.warn "ComputerUse sandbox: multiple mounts at #{dest}: #{group.map(&:mode).inspect}"
      end
    end
  end

  # ===========================================================================
  # bwrap executable discovery (no shell-out to `which`).
  # ===========================================================================
  helper :find_bwrap do
    # 1. Explicit config/env override.
    bwrap = config(:path, :bwrap, :sandbox, :sandbox_run, env: 'BWRAP_PATH')
    return bwrap unless bwrap.nil? || bwrap.to_s.empty?

    # 2. Search PATH manually.
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |dir|
      candidate = File.join(dir, 'bwrap')
      return candidate if File.executable?(candidate) && File.file?(candidate)
    end

    nil
  end

  # ===========================================================================
  # Error-stream condensing — keep failures succinct and root-cause first.
  #
  # Three noise sources historically drowned the real mistake in `stderr`:
  #
  #   1. CMD.cmd's ProcessFailed message re-serializes the ENTIRE bwrap argv
  #      (mount list + PATH), which alone runs to several KB.
  #   2. The Ruby-side rescue appended e.backtrace — the HOST stack
  #      (scout-ai tool loop, persist/lock frames), not the sandbox's.
  #   3. The program's own stderr was returned verbatim; a 5000-line flood
  #      exceeded scout-ai's 100,000-char tool-result cap, so the WHOLE
  #      result was dropped and the caller saw only a fingerprint.
  #
  # condense_stderr() rebuilds a failure stream as
  #   <root-cause lines first> + <bounded tail> + <elision markers>
  # collapsing repeats and dropping host framework frames.  The full,
  # uncondensed stream is persisted and returned as `stderr_full` so no
  # information is lost.
  # ===========================================================================

  # Does +line+ look like it carries error information?
  helper :error_line_match? do |line|
    return false if line.nil? || line.strip.empty?
    return false if line =~ /\A[\t ]/ && line !~ /error|exception|fatal|fail/i
    line =~ /
      \berror\b|\berror:|\Aerror|
      \bexception\b|\btraceback\b|
      \bfatal\b|\bfailed\b|\bfailure\b|\bcannot\b|\bcan't\b|
      \bno such file\b|\bpermission denied\b|\bnot found\b|\bexpected\b|
      \benoent\b|\beacces\b|\besrch\b|\baborted\b|
      \bkilled\b|\bterminated\b|\bsyntaxerror\b|\bnameerror\b|\btypeerror\b|
      \bvalueerror\b|\bkeyerror\b|\bindexerror\b|\bsegmentation fault\b|
      \bnot a git repository\b|\bundefined\b
    /ix
  end

  # Strip the giant flattened bwrap argv dump from a CMD.cmd ProcessFailed
  # message, leaving a short, useful summary instead of thousands of chars
  # of mount flags and PATH entries.
  helper :summarize_process_failed do |message|
    return message unless message =~ /\AProcess \d+ failed - /
    if (m = message.match(/\AProcess \d+ failed - (.+?) -- (.+?)( failed with error status \d+\.?)\z/m))
      argv = m[1]
      return message if argv.length <= 120
      payload_summary = m[2].strip.split(/\s+/).first(14).join(' ')
      return "Process failed - bwrap #{argv.split(/\s+/).first(2).join(' ')} ... -- #{payload_summary}#{m[3]} [full argv elided]"
    end
    if (m = message.match(/\AProcess \d+ failed - (.+)/m))
      argv = m[1]
      return message if argv.length <= 120
      words = argv.split(/\s+/)
      return "Process failed - bwrap #{words.first(6).join(' ')} ... #{words.last(3).join(' ')} [full argv elided]"
    end
    head = message[0, 120]
    rest = message.length > 240 ? " ... [elided #{message.length - 240} chars] ... " : ''
    tail = message[-120, 120].to_s
    head + rest + tail
  end

  # Condense a raw stderr stream into <= max_chars chars, root cause first.
  #
  # When +max_chars+ is 0 (or falsy) the stream is returned untouched
  # (explicit opt-out).
  helper :condense_stderr do |raw, max_chars: nil|
    max_chars ||= 4000
    max_chars = max_chars.to_i
    return raw.to_s if max_chars <= 0 || raw.nil?
    raw = raw.to_s

    return raw.chomp + "\n" if raw.length <= max_chars && !raw.include?('Process ')

    lines = raw.lines.map(&:chomp)

    # 1. Replace any giant ProcessFailed argv dump with its summary.
    lines = lines.map do |l|
      l =~ /\AProcess \d+ failed - / ? summarize_process_failed(l) : l
    end

    # 2. Drop host Ruby framework frames (gem internals, persist/lock,
    #    workflow step machinery).  They describe the CALLER's stack, not
    #    the sandbox failure.
    framework = %r{
      /gems/|/scout-essentials/lib|/scout-gear/lib|/scout-ai/lib|
      /rbbt-util/lib|/scout/persist|/open/lock|/workflow/step|
      chain_tools|process_calls|bin/scout:|`exec'\z|`cmd'\z
    }x
    dropped_frames = 0
    lines = lines.reject do |l|
      if l =~ framework && l !~ /error|failed|cannot|No such/i
        dropped_frames += 1
        true
      else
        false
      end
    end

    # 3. Collapse runs of identical lines into "line  [x N]".
    collapsed = []
    lines.each do |l|
      if collapsed.any? && collapsed.last[0] == l
        collapsed.last[1] += 1
      else
        collapsed << [l, 1]
      end
    end
    lines = collapsed.map { |l, n| n > 1 ? "#{l}  [x #{n}]" : l }

    # 4. Under budget after cleanup?  Return as-is.
    text = lines.join("\n")
    if text.length <= max_chars
      return text + (dropped_frames > 0 ? "\n[#{dropped_frames} framework backtrace frames elided]" : '')
    end

    # 5. Over budget: head = root-cause lines, tail = last lines.
    # Scan ALL error lines but keep at most 5 DISTINCT ones, so a real
    # error buried mid-stream (after thousands of repeated error-shaped
    # noise lines) still surfaces.
    error_idx = lines.each_index.select { |i| error_line_match?(lines[i]) }
    head_lines = []
    error_idx.each do |i|
      l = lines[i]
      next if head_lines.include?(l)
      head_lines << l
      break if head_lines.length >= 5
    end
    head = head_lines.empty? ? lines.first(3) : head_lines
    tail_keep = [(max_chars / 3) / 20, 5].max
    tail_lines = lines.last(tail_keep)
    omitted = lines.length - head.length - tail_lines.length

    parts = []
    parts.concat(head)
    parts << "... [#{omitted} lines omitted]" if omitted > 0
    parts.concat(tail_lines)
    text = parts.join("\n")

    # 6. Final hard cap on pathological single-line monsters.
    if text.length > max_chars
      keep = max_chars / 2
      text = text[0, keep] + "\n... [#{text.length - keep - 60} chars elided] ...\n" + text[-60, 60].to_s
    end

    text + (dropped_frames > 0 ? "\n[#{dropped_frames} framework backtrace frames elided]" : '')
  end

  # Persist +text+ for post-hoc debugging and return its path (nil on
  # failure).  Written under the step files_dir when available, else /tmp.
  helper :persist_full_stream do |text, label = 'stderr_full'|
    begin
      dir = respond_to?(:files_dir) ? files_dir : nil
      dir = nil if dir && !Open.exists?(dir.to_s)
      dir ||= Dir.mktmpdir
      path = File.join(dir.to_s, "#{label}.log")
      Open.write(path, text.to_s)
      path
    rescue
      nil
    end
  end

  # Build the failure hash for a failed exec, condensing stderr while
  # persisting the full stream for post-hoc debugging.
  helper :failure_result do |exit_status, stdout, stderr, prefix: nil|
    raw = [prefix, stderr].compact.join("\n")
    condensed = condense_stderr(raw)
    result = { exit_status: exit_status, stdout: stdout, stderr: condensed }
    if condensed != stderr.to_s || condensed != raw
      path = persist_full_stream(raw)
      result[:stderr_full] = path if path
    end
    result
  end

  # ===========================================================================
  # Executable resolution — resolve bare names via $PATH, then realpath.
  # ===========================================================================
  helper :resolve_executable do |exe|
    return exe.to_s if exe.nil? || exe.to_s.empty?
    resolved = safe_realpath(exe.to_s)
    return resolved if resolved
    # Bare name: search PATH for the real location.
    found = ENV['PATH'].to_s.split(File::PATH_SEPARATOR).find do |dir|
      candidate = File.join(dir, exe.to_s)
      File.executable?(candidate) && File.file?(candidate)
    end
    found ? safe_realpath(File.join(found, exe.to_s)) || exe.to_s : exe.to_s
  end

  # ===========================================================================
  # Runtime directory discovery for relocatable runtimes.
  # ===========================================================================

  # Compute the minimal set of directories needed to run +exe+ inside a
  # bwrap sandbox.  For relocatable runtime environments (RVM, rbenv,
  # Conda, pyenv, Homebrew, ...) the entire installation tree must be
  # mounted so that relative references resolve correctly.
  helper :runtime_dirs do |exe|
    resolved = safe_realpath(exe.to_s)
    return [] unless resolved

    dirs = []
    dirs << File.dirname(resolved)

    case resolved
    when %r{/\.rvm/rubies/},     # RVM Ruby
         %r{/\.rvm/gems/},       # RVM gems
         %r{/\.rbenv/versions/}, # rbenv
         %r{/\.pyenv/versions/}, # pyenv
         %r{/envs/},             # Conda/virtualenv
         %r{/Cellar/}            # Homebrew
      dirs << resolved.sub(%r{/bin/.*$}, '')
    end

    dirs.uniq
  end

  # Scan $PATH entries for known relocatable runtime layouts and return
  # their installation roots.  Needed for shell-based tasks where the
  # script may invoke interpreters that differ from the tool itself.
  helper :path_runtime_dirs do
    dirs = []
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |entry|
      next if entry.nil? || entry.empty?
      expanded = File.expand_path(entry)
      next unless File.directory?(expanded)

      case expanded
      when %r{/\.rvm/}, %r{/\.rbenv/}, %r{/\.pyenv/},
           %r{/envs/[^/]+/bin$}, %r{/Cellar/}
        dirs << expanded
        root = expanded.sub(%r{/bin/?$}, '')
        dirs << root unless root == expanded
      end
    end
    dirs.uniq
  end

  # ===========================================================================
  # sandbox_run — execute +executable+ with +argv+ inside a bwrap sandbox.
  #
  # Uses the mount planner to construct a principled, namespace-preserving
  # set of bind mounts.  Falls back to unsandboxed execution with a warning
  # when bwrap is not available.
  # ===========================================================================
  helper :sandbox_run do |executable, argv, options = {}, writable_paths = []|
    bwrap = find_bwrap

    timeout = options[:timeout]
    timeout = config(:timeout, :sandbox, :ComputerUse, :computer_use, env: 'SANDBOX_TIMEOUT,TIMEOUT', default: 3600 )
    timeout = case timeout
              when 'false', 'FALSE', 'False', 'no', 'none', 'nil', '0'
                nil
              when String
                timeout.to_i
              else
                timeout
              end

    bwrap_paths       = ComputerUse.get_allowed_paths(:bwrap_paths)
    bwrap_read_paths  = ComputerUse.get_allowed_paths(:bwrap_read_paths)

    writable_paths += ComputerUse.allowed_paths.dup
    read_paths      = ComputerUse.allowed_read_paths.dup

    writable_paths += bwrap_paths      if bwrap_paths
    read_paths     += bwrap_read_paths if bwrap_read_paths

    # Add per-call writable dirs (e.g. step files_dir) - callers may pass extras.
    writable_paths = Array(writable_paths).flatten.compact.uniq

    # Ensure root is writable so the sandbox can access repo files.
    root_dir = nil
    begin
      root_dir = ComputerUse.root
    rescue
    end
    if root_dir && !root_dir.to_s.empty?
      root_dir = root_dir.find if Path === root_dir
      writable_paths << root_dir.to_s
    end

    writable_paths.uniq!
    read_paths.uniq!

    use_bwrap = bwrap && !bwrap.to_s.empty? && bwrap.to_s != 'false' && bwrap.to_s != 'none'

    use_network = config(:use_network, :sandbox, :bwrap, default: 'true') == 'true'
    
    read_paths << '/etc/resolv.conf' if use_network

    if use_bwrap
      Log.debug "ComputerUse sandbox_run read_paths: #{read_paths.inspect}, writable_paths: #{writable_paths.inspect}"

      # --- Resolve the executable's real path ---
      resolved_exec = resolve_executable(executable)

      # --- Add runtime directories needed by the resolved executable ---
      read_paths.concat(runtime_dirs(resolved_exec))

      # --- Scan $PATH for known relocatable runtime layouts ---
      read_paths.concat(path_runtime_dirs)

      # --- Plan all mounts using the mount planner ---
      mounts = plan_mounts(read_paths, writable_paths)

      log_mount_plan(mounts)
      validate_mount_plan(mounts)

      # --- Build bwrap argument list (as an argv array, never a string) ---
      bwrap_args = ['--unshare-all', '--die-with-parent']

      # Bind /tmp writable so temp files survive across subprocesses.
      bwrap_args.concat(['--bind', '/tmp', '/tmp'])

      bwrap_args.concat(['--proc', '/proc'])
      bwrap_args.concat(['--dev', '/dev'])

      # Set HOME and PATH explicitly for deterministic execution.
      home = ENV['HOME']
      if home && !home.empty?
        bwrap_args.concat(['--setenv', 'HOME', home])
      end

      path_env = ENV['PATH']
      if path_env && !path_env.empty?
        bwrap_args.concat(['--setenv', 'PATH', path_env])
      end

      # --- Emit application/user mounts from the planned mount list ---
      # Mounts are already sorted parents-before-children by plan_mounts.
      mounts.each do |m|
        flag = mount_mode_flag(m.mode)
        bwrap_args.concat([flag, m.source, m.destination])
      end

      if use_network
        bwrap_args << '--share-net'
      end

      # Ensure we chdir into the repo root if available.
      if root_dir && !root_dir.to_s.empty?
        bwrap_args.concat(['--chdir', root_dir.to_s])
      end

      # End of bwrap args marker.
      bwrap_args << '--'

      # --- Build the full command as an argv array ---
      full_argv = [bwrap.to_s] + bwrap_args + [resolved_exec] + Array(argv).map(&:to_s)

      begin
        io = CMD.cmd(full_argv, options.merge(save_stderr: true, pipe: false, no_fail: false, log: true, timeout: timeout))
        out = io.read.to_s
        err = io.std_err.to_s
        status = io.exit_status
        if status == 0 && err.length <= 4000
          { stdout: out, stderr: err, exit_status: status }
        else
          # Failure (or oversized stream): condense, keep raw copy on disk.
          failure_result(status, out, err)
        end
      rescue => e
        # CMD.cmd re-raises with the whole flattened bwrap argv embedded
        # in the message; failure_result() summarizes it and drops the
        # HOST backtrace, which only describes the caller's stack.
        begin
          program_err = e.io ? e.io.std_err.to_s : nil
        rescue
          program_err = nil
        end
        prefix = (e.message || e.class.to_s)
        failure_result(-1, nil, program_err || '', prefix: prefix)
      end
    else
      # Fallback: warn and run unsandboxed.
      if defined?(Log)
        Log.warn 'bwrap not found — running unsandboxed'
      else
        warn 'bwrap not found — running unsandboxed'
      end

      full_argv = [executable.to_s] + Array(argv).map(&:to_s)

      begin
        io = CMD.cmd(full_argv, options.merge(save_stderr: true, pipe: false, no_fail: false, log: true, timeout: timeout))
        out = io.read.to_s
        err = io.std_err.to_s
        status = io.exit_status
        if status == 0 && err.length <= 4000
          { exit_status: status, stdout: out, stderr: err }
        else
          failure_result(status, out, err)
        end
      rescue => e
        begin
          program_err = e.io ? e.io.std_err.to_s : nil
        rescue
          program_err = nil
        end
        prefix = (e.message || e.class.to_s)
        failure_result(-1, nil, program_err || '', prefix: prefix)
      end
    end
  end

  # ===========================================================================
  # cmd_json — build interpreter args and delegate to sandbox_run.
  # ===========================================================================
  helper :cmd_json do |tool, cmd, options = {}, writable_paths = []|
    # Normalize command and stdin
    stdin_data = options[:in]

    # Determine interpreter name (tool can be symbol or string)
    interpreter = tool.to_s

    # Build args array based on tool type and provided cmd
    args_array = if Array === cmd
                   cmd
                 elsif interpreter == 'bash'
                   if stdin_data && (cmd.nil? || cmd.to_s.empty?)
                     ['-s']
                   else
                     ['-c', cmd.to_s]
                   end
                 elsif interpreter.start_with?('python') || interpreter == 'ruby' || interpreter == 'Rscript' || interpreter == 'R'
                   # For python, ruby and R-like interpreters prefer running files when a path is given.
                   if cmd && File.exist?(cmd.to_s)
                     if interpreter == 'R'
                       ['--slave', '-f', cmd.to_s]
                     else
                       [cmd.to_s]
                     end
                   else
                     if interpreter == 'R' && stdin_data
                       ['-']
                     else
                       stdin_data ? ['-'] : [cmd.to_s]
                     end
                   end
                 else
                   cmd ? [cmd.to_s] : []
                 end

    # Ensure args are strings
    args_array = Array(args_array).collect(&:to_s)

    # Collect writable dirs to expose inside the sandbox
    writable_paths = ComputerUse.get_allowed_paths(:allowed_paths)
    begin
      writable_paths << self.files_dir if respond_to?(:files_dir) && self.files_dir && Open.exists?(self.files_dir)
    rescue => _e
    end

    # Run inside sandbox (bwrap) when available, fallback to unsandboxed
    sandbox_run(tool, args_array, options, writable_paths)
  end

  # ===========================================================================
  # Task definitions
  # ===========================================================================

  desc <<-EOF
Run a bash command.

Returns a JSON object with two keys, stderr and stdout, pointing to the STDOUT
and STDERR outputs as strings, and exit_status, the exit status of the process
  EOF
  input :cmd, :string, 'Bash command to run', nil, required: true
  extension :json
  task 'bash' => :text do |cmd|
    Log.medium "Bash\n" + cmd
    cmd_json :bash, cmd
  end

  desc <<-EOF
Run a file or code using python.

If `file` is provided it will be executed. Otherwise `code` will be written to a temporary
file under the task `root` and executed. Returns a JSON object with keys stdout,
stderr and exit_status.
  EOF
  input :code, :text, 'Python code to run (ignored if file provided)'
  input :file, :path, 'File to run'
  extension :json
  task :python => :text do |code, file|
    if file && !file.to_s.empty?
      file = normalize file
      target = file
    elsif code && !code.to_s.empty?
      tmp = file('script.py')
      tmp.write code
      target = tmp
    else
      raise ParameterException, 'Provide either a file or code to run'
    end

    cmd_name = nil
    ['python3', 'python'].each do |p|
      begin
        io_test = CMD.cmd(p.to_sym, '--version', save_stderr: true, pipe: true, no_fail: true)
        io_test.join
        if io_test.exit_status == 0 || io_test.read.to_s.length > 0
          cmd_name = p
          break
        end
      rescue
        next
      end
    end
    cmd_name ||= 'python'

    begin
      cmd_json cmd_name, target
    rescue => e
      raise ScoutException, e.message
    end
  end

  desc <<-EOF
Run a file or code using ruby.

If `file` is provided it will be executed. Otherwise `code` will be written to a temporary
file under the task `root` and executed.

Returns a JSON object with keys stdout, stderr and exit_status.
  EOF
  input :code, :text, 'Ruby code to run (ignored if file provided)'
  input :file, :path, 'File to run'
  extension :json
  task :ruby => :text do |code, file|
    if file && !file.to_s.empty?
      file = normalize file
      target = file
    elsif code && !code.to_s.empty?
      tmp = file('script.rb')
      tmp.write code
      target = tmp
    else
      raise ParameterException, 'Provide either a file or code to run'
    end

    begin
      cmd_json :ruby, target
    rescue => e
      raise ScoutException, e.message
    end
  end

  desc <<-EOF
Run a file or code using R.

If `file` is provided it will be executed. Otherwise `code` will be written to a temporary
file under the task `root` and executed.

Returns a JSON object with keys stdout, stderr and exit_status.
  EOF
  input :code, :text, 'R code to run (ignored if file provided)'
  input :file, :path, 'File to run'
  extension :json
  task :r => :text do |code, file|
    if file && !file.to_s.empty?
      file = normalize file
      target = file
    elsif code && !code.to_s.empty?
      tmp = file('script.R')
      tmp.write code
      target = tmp
    else
      raise ParameterException, 'Provide either a file or code to run'
    end

    cmd_name = nil
    ['Rscript', 'R'].each do |p|
      begin
        io_test = CMD.cmd(p.to_sym, '--version', save_stderr: true, pipe: true, no_fail: true)
        io_test.join
        if io_test.exit_status == 0 || io_test.read.to_s.length > 0
          cmd_name = p
          break
        end
      rescue
        next
      end
    end
    cmd_name ||= 'Rscript'

    begin
      cmd_json cmd_name, target
    rescue => e
      raise ScoutException, e.message
    end
  end

  export_exec :bash
  export_exec :python
  export_exec :ruby
  export_exec :r
end
