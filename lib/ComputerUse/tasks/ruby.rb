module ComputerUse

  
  @root = Dir.pwd
  singleton_class.attr_accessor :root

  helper :root_holds_file do |path|
    ! Misc.path_relative_to(File.expand_path(ComputerUse.root), path).nil?
  end

  desc <<-EOF
Run a file using ruby. 

Returns a JSON object with two keys, stderr and stdout, pointing
to the STDOUT and STDERR outputs as strings.
  EOF
  input :file, :path, 'File to run'
  extension :json
  task :ruby => :text do |file,root|
    root_holds_file file

    io = CMD.cmd(:ruby, file, save_stderr: true, pipe: true)

    text = io.read
    io.join
    {stdout: text, stderr: io.std_err}
  end

  desc <<-EOF
Write a file.
  EOF
  input :file, :path, 'Path to the file to write', nil, required: true
  input :content, :text, 'Content to write into the file', nil, required: true
  task :write => :string do |file,content,root|
    root_holds_file file

    io = CMD.cmd(:ruby, file, save_stderr: true, pipe: true)

    "Content saved into #{file}: #{Log.fingerprint content}"
  end

  desc <<-EOF
Read a file.
  EOF
  input :file, :path, 'Path to the file to read', nil, required: true
  input :limit, :integer, 'Number of lines to return from chosend end of the file'
  input :file_end, :select, 'Side of file to read', :head, select_options: %w(head tail)
  task :read => :text do |file,limit,file_end,root|
    root_holds_file file

    text = Open.read file
    if limit
      limit = limit.to_i
      if limit > 0
        case file_end.to_s
        when 'head'
          text.split("\n")[0..limit-1]
        when 'tail'
          text.split("\n")[limit-1..-1]
        else
          raise ParameterException, "Unknown file_end: #{Log.fingerprint file_end}"
        end
      else
        raise ParameterException, "Wrong limit: #{Log.fingerprint limit}"
      end
    else
      text
    end
  end

  desc <<-EOF
List all the files in a directory
  EOF
  input :directory, :path, 'Directory to list', nil, required: true
  task :list_directory => :array do |directory,root|
    root_holds_file directory
  end

  desc <<-EOF

Return stats if a file.

Stats: size, modification time, number of lines, binary or
not, number of lines (if not binary), etc

  EOF
  input :file, :path, 'File with stats to report', nil, required: true
  extension :json
  task :file_stats => :text do |file,root|
    root_holds_file file
  end

  export_exec :ruby, :list_directory, :write, :read, :file_stats
end
