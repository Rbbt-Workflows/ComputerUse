module ComputerUse

  helper :cmd_json do |tool,cmd=nil,options={}|
    begin
      io = CMD.cmd(tool, cmd, options.merge(save_stderr: true, pipe: false, no_fail: true, log: true))
      {stdout: io.read, stderr: io.std_err, exit_status: io.exit_status}
    rescue
      raise $!
      raise ScoutException 
    end
  end

  desc <<-EOF
Run a bash command.

Returns a JSON object with two keys, stderr and stdout, pointing to the STDOUT
and STDERR outputs as strings, and exit_status, the exit status of the process
  EOF
  input :cmd, :string, 'Bash command to run to run', nil, required: true
  extension :json
  task 'bash' => :text do |cmd|
    cmd_json cmd
  end

  export_exec :bash
end
