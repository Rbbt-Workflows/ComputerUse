module ComputerUse

  helper :cmd_json do |tool, cmd, options={}|
    begin
      io = CMD.cmd(tool, cmd, options.merge(save_stderr: true, pipe: false, no_fail: true, log: true))
      {stdout: io.read, stderr: io.std_err, exit_status: io.exit_status}
    rescue => e
      raise ScoutException, e.message
    end
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
      tmp = file('script')
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
file under the task `root` and executed. Returns a JSON object with keys stdout,
stderr and exit_status.
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
      tmp = file('script')
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
Apply a patch to the files under ComputerUse.root.

Inputs:
- patch: the patch content (unified diff or other format accepted by the `patch` utility)
- strip: the -pN argument for the patch command (defaults to 0)
- dry_run: if true, runs patch with --dry-run (check only, do not modify files)

Returns patch output on success, raises ParameterException on failure.
  EOF
  input :patch, :text, 'Patch content', nil, required: true
  input :strip, :integer, 'Number for patch -pN (strip count)', 0
  input :dry_run, :boolean, 'If true, perform a dry-run (do not apply)', false
  extension :json
  task :patch => :text do |patch_text, strip, dry_run, root|
    patch_text ||= ''
    strip = (strip || 0).to_i
    dry_run = !!dry_run

    Dir.chdir(ComputerUse.root) do
      # Build command; pass args directly to avoid shell.
      cmd = ["-p#{strip}"]
      cmd << '--dry-run' if dry_run

      # Open the tempfile for reading to pass as stdin.
      cmd_json :patch, cmd * ' ', in: patch_text
    end
  end

  export_exec :bash
  export_exec :python
  export_exec :ruby
  export_exec :patch
end
