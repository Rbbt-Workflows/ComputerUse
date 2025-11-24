module ComputerUse

  helper :cmd_json do |tool, cmd, options={}|
    begin
      io = CMD.cmd(tool, options.merge(save_stderr: true, pipe: false, no_fail: true, log: true, in: cmd))
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
      root_holds_file file
      target = file
    elsif code && !code.to_s.empty?
      tmp = File.join(ComputerUse.root, "agent_script_#{Time.now.to_i}_#{rand(1000)}.py")
      File.open(tmp, 'w') { |f| f.write(code) }
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
      io = CMD.cmd(cmd_name.to_sym, target, save_stderr: true, pipe: true)
      text = io.read
      io.join
      {stdout: text, stderr: io.std_err, exit_status: io.exit_status}
    rescue => e
      raise ScoutException, e.message
    end
  end

  export_exec :bash
  export_exec :python
end
