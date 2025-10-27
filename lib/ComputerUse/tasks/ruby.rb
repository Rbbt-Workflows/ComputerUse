module ComputerUse

  desc <<-EOF
Run a file using ruby.

Returns a JSON object with two keys, stderr and stdout, pointing
to the STDOUT and STDERR outputs as strings.
  EOF
  input :file, :path, 'File to run'
  extension :json
  task :ruby => :text do |file,root|
    root_holds_file file

    begin
      io = CMD.cmd(:ruby, file, save_stderr: true, pipe: true)

      text = io.read
      io.join
      {stdout: text, stderr: io.std_err}
    rescue
      raise ScoutException, io.std_err
    end
  end

  export_exec :ruby
end
