module ComputerUse
  @root = Dir.pwd
  singleton_class.attr_accessor :root

  helper :root_holds_file do |path|
    raise ParameterException, "File #{path} does not exist" unless Open.exists?(path) || Open.directory?(path)
    if File.expand_path(ComputerUse.root) != File.expand_path(path)
      if Misc.path_relative_to(File.expand_path(ComputerUse.root), path).nil?
        raise ParameterException, "File #{path} not under #{ComputerUse.root}"
      end
    end
  end

  desc <<-EOF
Write a file.
  EOF
  input :file, :path, 'File to write', nil, required: true
  input :content, :text, 'Content to write into the file', nil, required: true
  task :write => :string do |file,content|
    root_holds_file file
    file = file.find if Path === file
    file = File.expand_path(file)
    Open.write file, content
  end

  desc <<-EOF
Read a file. Don't specify a limit to read it complete. If you specify a limit specify a file_end which can be head or tail
  EOF
  input :file, :path, 'Path to the file to read', nil, required: true
  input :limit, :integer, 'Number of lines to return from chosend end of the file'
  input :file_end, :select, 'Side of file to read', :head, select_options: %w(head tail)
  task :read => :text do |file,limit,file_end,root|
    root_holds_file file

    raise ParameterException, 'File is really a directory, can not read' if Open.directory?(file)
    text = Open.read file
    if limit
      limit = limit.to_i
      if limit > 0
        lines = text.split("\n")
        next text if lines.length <= limit

        case file_end.to_s
        when 'head'
          lines[0..limit-1] * "\n"
        when 'tail'
          lines[limit-1..-1] * "\n"
        else
          raise ParameterException, "Unknown file_end must be head or tail: #{Log.fingerprint file_end}"
        end
      else
        raise ParameterException, "Wrong limit: #{Log.fingerprint limit}"
      end
    else
      text
    end
  end

  desc <<-EOF
List all the files and subdirectories in a directory and returns the files and
directories separatedly, and optionaly some file stats like size, and
modification time.

Example: {files: ['foo', 'bar/bar'], directories: ['bar'], stats: {'foo' => {size: 100, mtime=#{Time.now}}}, 'bar/bar' => {size: 200, mtime=#{Time.now - 100}}} }
  EOF
  input :directory, :path, 'Directory to list', nil, required: true
  input :recursive, :boolean, 'List recursively', true
  input :stats, :boolean, 'Return some stats for the files', false
  extension :json
  task :list_directory => :text do |directory,recursive,stats|
    root_holds_file directory
    files = if recursive
              Path.setup(directory).glob('**/**')
            else
              Path.setup(directory).glob('*')
            end

    info = {files: [], directories: []}

    files.each do |file|
      if file.directory?
        info[:directories] << file.find
      else
        info[:files] << file.find
      end
    end

    if stats
      info[:stats] = {}
      info[:files].each do |file|
        info[:stats][file] = {
          size: File.size(file),
          mtime: Open.mtime(file)
        }

      end
    end

    info.to_json
  end

  desc <<-EOF

Return stats if a file.

Stats: size, modification time, binary or
not, number of lines (if not binary), etc

  EOF
  input :file, :path, 'File with stats to report', nil, required: true
  extension :json
  task :file_stats => :text do |file,root|
    root_holds_file file
    file = Path.setup(file)
    stats = {}
    stats[:type] = file.directory? ? :directory : :file
    if ! file.directory?
      stats[:binary] = false
      stats[:size] = File.size(file)
      stats[:lines] = Open.read(file).split("\n").length
      stats[:mtime] = Open.mtime(file)
    end
    stats.to_json
  end

  export_exec :list_directory, :write, :read, :file_stats
end
