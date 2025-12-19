module ComputerUse
  require 'open3'

  helper :sandbox_run do |tool, cmd, options = {}, writable_dirs = ['~/.scout/tmp', '~/.scout/var']|
    # Prefer explicit bwrap path if provided in env
    bwrap = ENV['BWRAP_PATH'] || `which bwrap 2>/dev/null`.strip

    if bwrap && !bwrap.empty?
      # Build bwrap argument list. Bind readonly system dirs so interpreter can run.
      bwrap_args = ['--unshare-all', '--tmpfs', '/tmp', '--proc', '/proc', '--dev', '/dev']

      # Also bind any additional writable dirs requested (e.g. self.files_dir)
      Array(writable_dirs).each do |d|
        next unless d
        bwrap_args += ['--bind', d.to_s, d.to_s]
      end

      # Readonly binds for common system paths so interpreters and libs are available
      %w(/bin /usr /lib /lib64 /etc ~).each do |p|
        if File.exist?(File.expand_path(p))
          bwrap_args += ['--ro-bind', p, p]
        end
      end

      # Bind the ComputerUse.root writable so the sandbox can access repo files
      begin
        root_dir = ComputerUse.root
        if root_dir && !root_dir.to_s.empty?
          bwrap_args += ['--bind', root_dir.to_s, root_dir.to_s]
        end
      rescue => _e
        # ignore if root not available
      end


      # Ensure we chdir into the repo root if available
      if root_dir && !root_dir.to_s.empty?
        bwrap_args += ['--chdir', root_dir.to_s]
      end

      # End of bwrap args marker
      bwrap_args << '--'

      cmd = (bwrap_args + [tool.to_s])*" " << ' ' << (Array === cmd ? cmd*" " : cmd.to_s)

      io = CMD.cmd(bwrap, cmd, options.merge(save_stderr: true, pipe: false, no_fail: true, log: true))
      {stdout: io.read, stderr: io.std_err, exit_status: io.exit_status}
    else
      # Fallback: warn and run unsandboxed
      if defined?(Log)
        Log.warn 'bwrap not found — running unsandboxed'
      else
        warn 'bwrap not found — running unsandboxed'
      end
      io = CMD.cmd(tool, cmd, options.merge(save_stderr: true, pipe: false, no_fail: true, log: true))
      {stdout: io.read, stderr: io.std_err, exit_status: io.exit_status}
    end
  end

  helper :cmd_json do |tool, cmd, options={}|
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
    writable = []
    begin
      writable << self.files_dir if respond_to?(:files_dir) && self.files_dir && Open.exists?(self.files_dir)
    rescue => _e
    end

    # Run inside sandbox (bwrap) when available, fallback to unsandboxed with a warning
    sandbox_run(tool, cmd, options, writable)
  end

  desc <<-EOF
Run a bash command.

Returns a JSON object with two keys, stderr and stdout, pointing to the STDOUT
and STDERR outputs as strings, and exit_status, the exit status of the process
  EOF
  input :cmd, :string, 'Bash command to run', nil, required: true
  extension :json
  task 'bash' => :text do |cmd|
    cmd_json :bash, nil, in: cmd
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
      root_holds_file file
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
      root_holds_file file
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
      root_holds_file file
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
