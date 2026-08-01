module ComputerUse
  require 'open3'

  # Compute the canonical realpath of a path, returning nil if the path
  # does not exist or cannot be resolved.
  helper :safe_realpath do |path|
    return nil if path.nil?
    File.realpath(path.to_s)
  rescue Errno::ENOENT, Errno::ENOTDIR, ArgumentError
    nil
  end

  # Determine the destination path for a bwrap bind mount.
  #
  # For system directories whose symlink topology is part of the filesystem
  # ABI (/bin -> /usr/bin, /lib64 -> /usr/lib64, ...), we must preserve the
  # original path as the destination so that programs inside the sandbox see
  # the symlinks they expect.
  #
  # For user-supplied directories, if the destination traverses a symlink
  # (e.g. /home/user/tmp -> /fast/user/tmp), we fall back to the realpath
  # so bwrap can create the mount point.
  helper :bind_destination do |path|
    path = path.to_s
    # System paths whose symlinks are part of the ABI - never canonicalize.
    case path
    when '/bin', '/lib', '/lib64', '/lib32',
         '/usr', '/usr/bin', '/usr/lib', '/usr/lib64', '/usr/lib32',
         '/etc', '/opt', '/sbin', '/usr/sbin'
      return path
    end

    # Check whether the *directory component* of path traverses a symlink.
    # If dirname(path) != realpath(dirname(path)), then an intermediate
    # component is a symlink and bwrap would fail to create the mount point.
    dir = File.dirname(path)
    real_dir = safe_realpath(dir)
    return path if real_dir.nil? || real_dir == dir

    # Intermediate symlink detected: use the realpath as destination so
    # bwrap can reach it.
    safe_realpath(path) || path
  rescue
    path
  end

  # Add a single bind mount to the bwrap_args array.
  # +mode+ is '--bind' (writable) or '--ro-bind' (read-only).
  helper :add_bind_mount do |args, mode, path|
    path = File.expand_path(path.to_s)
    return args unless File.exist?(path)

    src = safe_realpath(path)
    return args if src.nil?

    dst = bind_destination(path)

    args.concat([mode, src, dst])
  end

  # Remove paths whose *destination* is already covered by another path's
  # destination.  This prevents redundant mounts such as binding both
  # /fast and /fast/mvazque2/tmp when the latter is already reachable
  # through the former.
  #
  # IMPORTANT: we deduplicate based on the *destination* (what is visible
  # inside the sandbox), NOT the canonical source.  This is critical because
  # system paths like /bin (canonical /usr/bin) must NOT be filtered out
  # just because /usr is already bound -- they need their own mount point so
  # the symlink topology (/bin, /lib64, ...) is preserved inside the sandbox.
  helper :deduplicate_paths do |paths|
    # Build [original, destination] pairs, skipping non-existent paths.
    pairs = paths.map do |p|
      expanded = File.expand_path(p.to_s)
      next nil unless File.exist?(expanded)
      dst = bind_destination(expanded)
      [expanded, dst]
    end.compact

    # Sort by destination so parents come before children.
    pairs.sort_by! { |_orig, dst| dst }

    kept = []
    kept_destinations = []

    pairs.each do |orig, dst|
      # Skip if this destination is already under a kept parent destination.
      next if kept_destinations.any? { |parent| dst == parent || dst.start_with?(parent + "/") }
      kept << orig
      kept_destinations << dst
    end

    kept
  end

  # Locate the bwrap executable without shelling out to `which`.
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

  # Resolve an executable to its canonical absolute path.
  #
  # If +exe+ is already an absolute or relative path to an existing file,
  # symlinks are resolved via File.realpath.
  #
  # If +exe+ is a bare name (e.g. "ruby", "python3"), it is looked up in
  # $PATH first, then symlinks are resolved.  This is critical so that
  # runtime_dirs() can correctly identify the installation tree for
  # relocatable runtimes like RVM, pyenv, or Conda.
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

  # Compute the minimal set of directories needed to run +exe+ inside a
  # bwrap sandbox.  This goes beyond just the bin/ directory containing the
  # executable: for relocatable runtime environments (RVM, rbenv, Conda,
  # pyenv, Homebrew, ...) the entire installation tree must be mounted so
  # that relative references (../lib, ../share, gem directories, etc.)
  # resolve correctly.
  #
  # Returns an Array of directory paths (deduplicated).  Returns an empty
  # Array if the executable cannot be resolved.
  helper :runtime_dirs do |exe|
    resolved = safe_realpath(exe.to_s)
    return [] unless resolved

    dirs = []
    dirs << File.dirname(resolved)

    # Detect common relocatable runtime layouts and add their installation
    # root (the directory above bin/).
    case resolved
    when %r{/\.rvm/rubies/},     # RVM Ruby:  .../.rvm/rubies/ruby-3.3.1/bin/ruby
         %r{/\.rvm/gems/},       # RVM gems:  .../.rvm/gems/ruby-3.3.1/bin/rake
         %r{/\.rbenv/versions/}, # rbenv:     .../.rbenv/versions/3.3.1/bin/ruby
         %r{/\.pyenv/versions/}, # pyenv:     .../.pyenv/versions/3.12.0/bin/python
         %r{/envs/},             # Conda/virtualenv: .../envs/myenv/bin/python
         %r{/Cellar/}            # Homebrew:  /opt/homebrew/Cellar/ruby/3.3.1/bin/ruby
      dirs << resolved.sub(%r{/bin/.*$}, '')
    end

    dirs.uniq
  end

  # Scan $PATH entries for known relocatable runtime layouts (RVM, rbenv,
  # pyenv, Conda, Homebrew) and return their installation roots.
  #
  # Unlike runtime_dirs(exe) which derives dirs from a single resolved
  # executable, this helper ensures that ALL relocatable runtimes visible
  # through $PATH are mounted.  This is necessary for shell-based tasks
  # (e.g. `bash -c 'type ruby'`) where the script may invoke interpreters
  # that differ from the tool itself.
  #
  # Only directories matching recognized runtime-manager patterns are
  # returned — arbitrary $PATH entries are NOT bound.
  helper :path_runtime_dirs do
    dirs = []
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |entry|
      next if entry.nil? || entry.empty?
      expanded = File.expand_path(entry)
      next unless File.directory?(expanded)

      case expanded
      when %r{/\.rvm/}, %r{/\.rbenv/}, %r{/\.pyenv/},
           %r{/envs/[^/]+/bin$}, %r{/Cellar/}
        # Add the bin dir itself...
        dirs << expanded
        # ...and its installation root (parent of bin).
        root = expanded.sub(%r{/bin/?$}, '')
        dirs << root unless root == expanded
      end
    end
    dirs.uniq
  end

  # Run +executable+ with +argv+ (an Array of string arguments) inside a
  # bwrap sandbox when available, falling back to unsandboxed execution
  # with a warning otherwise.
  #
  # +executable+ is the interpreter/program path (e.g. "bash", "python3",
  # "/usr/bin/ruby").  Symlinks on the executable itself are resolved via
  # File.realpath before execution.
  #
  # +argv+ is the argument list for the executable (e.g. ["-c", "echo hi"]).
  helper :sandbox_run do |executable, argv, options = {}, writable_dirs = []|
    bwrap = find_bwrap

    bwrap_dirs       = ComputerUse.get_allowed_dirs(:bwrap_dirs)
    bwrap_read_dirs  = ComputerUse.get_allowed_dirs(:bwrap_read_dirs)

    writable_dirs += ComputerUse.allowed_dirs.dup
    read_dirs      = ComputerUse.allowed_read_dirs.dup

    writable_dirs += bwrap_dirs      if bwrap_dirs
    read_dirs     += bwrap_read_dirs if bwrap_read_dirs

    # Add per-call writable dirs (e.g. step files_dir) - callers may pass extras.
    writable_dirs = Array(writable_dirs).flatten.compact.uniq

    # Ensure root is writable so the sandbox can access repo files.
    root_dir = nil
    begin
      root_dir = ComputerUse.root
    rescue
    end
    if root_dir && !root_dir.to_s.empty?
      writable_dirs << root_dir.to_s
    end

    writable_dirs.uniq!
    read_dirs.uniq!
    read_dirs -= writable_dirs

    use_bwrap = bwrap && !bwrap.to_s.empty? && bwrap.to_s != 'false' && bwrap.to_s != 'none'

    if use_bwrap
      Log.debug "ComputerUse sandbox_run read_dirs: #{read_dirs.inspect}, writable_dirs: #{writable_dirs.inspect}"

      # --- Build bwrap argument list (as an argv array, never a string) ---

      bwrap_args = ['--unshare-all']

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

      # --- Resolve the executable's real path (handles symlinked interpreters) ---
      resolved_exec = resolve_executable(executable)

      # --- Add runtime directories needed by the resolved executable ---
      # This ensures relocatable runtime trees (RVM, Conda, pyenv, ...) are
      # mounted so the interpreter can find its libs, gems, etc.
      read_dirs.concat(runtime_dirs(resolved_exec))

      # --- Also scan $PATH for known relocatable runtime layouts ---
      # This is needed for shell-based tasks (e.g. `bash -c 'type ruby'`)
      # where the script may invoke interpreters that differ from the tool
      # (bash) being sandboxed.
      read_dirs.concat(path_runtime_dirs)

      # --- Deduplicate read and writable dirs to avoid redundant mounts ---
      deduped_read     = deduplicate_paths(read_dirs)
      deduped_writable = deduplicate_paths(writable_dirs)
      # Remove writable paths from the read list (writable takes precedence).
      writable_destinations = deduped_writable.map { |p| bind_destination(File.expand_path(p.to_s)) }.compact
      deduped_read = deduped_read.reject do |p|
        dst = bind_destination(File.expand_path(p.to_s))
        dst && writable_destinations.any? { |wdst| dst == wdst || dst.start_with?(wdst + "/") }
      end

      # --- Bind read-only directories ---
      deduped_read.each do |d|
        add_bind_mount(bwrap_args, '--ro-bind', d)
      end

      # --- Bind writable directories ---
      deduped_writable.each do |d|
        add_bind_mount(bwrap_args, '--bind', d)
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
        io = CMD.cmd(full_argv, options.merge(save_stderr: true, pipe: false, no_fail: false, log: true))
        { stdout: io.read, stderr: io.std_err, exit_status: io.exit_status }
      rescue => e
        exception_str = e.message + "\n" + (e.backtrace * "\n")
        { exit_status: -1, stdout: nil, stderr: exception_str }
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
        io = CMD.cmd(full_argv, options.merge(save_stderr: true, pipe: false, no_fail: false, log: true))
        { exit_status: io.exit_status, stdout: io.read, stderr: io.std_err }
      rescue => e
        exception_str = e.message + "\n" + (e.backtrace * "\n")
        { exit_status: -1, stdout: nil, stderr: exception_str }
      end
    end
  end

  helper :cmd_json do |tool, cmd, options = {}, writable_dirs = []|
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
                       # When using 'R' as the interpreter, supply flags to run a file non-interactively
                       ['--slave', '-f', cmd.to_s]
                     else
                       [cmd.to_s]
                     end
                   else
                     # If no file, read from stdin when provided, otherwise pass the cmd as single arg
                     if interpreter == 'R' && stdin_data
                       # For 'R' reading from stdin, use '-' to indicate stdin
                       ['-']
                     else
                       stdin_data ? ['-'] : [cmd.to_s]
                     end
                   end
                 else
                   # Generic program: if cmd present and is a string, supply as single arg; if nil, empty args
                   cmd ? [cmd.to_s] : []
                 end

    # Ensure args are strings
    args_array = Array(args_array).collect(&:to_s)

    # Collect writable dirs to expose inside the sandbox: prefer step files_dir if available
    writable_dirs = ComputerUse.get_allowed_dirs(:allowed_dirs)
    begin
      writable_dirs << self.files_dir if respond_to?(:files_dir) && self.files_dir && Open.exists?(self.files_dir)
    rescue => _e
    end

    # Run inside sandbox (bwrap) when available, fallback to unsandboxed with a warning
    sandbox_run(tool, args_array, options, writable_dirs)
  end

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
    # Prefer provided file, otherwise write code to a temp file in root
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

    # Prefer python3 if available
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
    # Prefer provided file, otherwise write code to a temp file in root
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
    # Prefer provided file, otherwise write code to a temp file in root
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

    # Prefer Rscript if available, otherwise fall back to R
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
