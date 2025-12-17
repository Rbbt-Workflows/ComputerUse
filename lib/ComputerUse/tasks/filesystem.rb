module ComputerUse
  @root = Dir.pwd
  singleton_class.attr_accessor :root

  helper :normalize do |path|
    path = "./#{path}" unless path.start_with?('/')
    return path if File.expand_path(ComputerUse.root) == File.expand_path(path)

    if Open.exists?(path) || Open.directory?(path)
      return path if Open.realpath(ComputerUse.root) == Open.realpath(path)
      if Misc.path_relative_to(Open.realpath(ComputerUse.root), Open.realpath(path)).nil?
        raise ParameterException, "File #{path} not under #{ComputerUse.root}"
      end
    else
      if Misc.path_relative_to(File.expand_path(ComputerUse.root), File.expand_path(path)).nil?
        raise ParameterException, "File #{path} not under #{ComputerUse.root}"
      end
    end
    return path
  end

  desc <<-EOF
Write a file.
  EOF
  input :file, :path, 'File to write', nil, required: true
  input :content, :text, 'Content to write into the file', nil, required: true
  task :write => :string do |file,content|
    file = normalize file
    Open.write file, content
    "success writing to #{file}"
  end

  desc <<-EOF
Read a file. Don't specify a limit to read it complete. If you specify a limit specify a file_end which can be head or tail
  EOF

  desc <<-EOF
Read a file. Don't specify a limit to read it complete. If you specify a limit specify a file_end which can be head or tail.
You may also specify start (line offset). For head start is 0-based from the beginning; for tail start is 0-based from the end (0 == last line).
  EOF
  input :file, :path, 'Path to the file to read', nil, required: true
  input :limit, :integer, 'Number of lines to return from chosen end of the file'
  input :file_end, :select, 'Side of file to read', :head, select_options: %w(head tail)
  input :start, :integer, 'Line offset: for head -> 0-based from start; for tail -> 0-based from end (0 == last line)', 0
  task :read => :text do |file, limit, file_end, start|
    file = normalize file

    raise ParameterException, 'File not found' unless Open.exists?(file)
    raise ParameterException, 'File is really a directory, can not read' if Open.directory?(file)

    # no limit -> read full file (same behaviour as before)
    unless limit && limit.to_i > 0
      next Open.read(file)
    end

    limit = limit.to_i
    raise ParameterException, "Wrong limit: #{Log.fingerprint limit}" if limit <= 0

    start = (start || 0).to_i
    raise ParameterException, "Wrong start: #{Log.fingerprint start}" if start < 0

    case file_end.to_s
    when '', 'head'
      # Read from the start (or from start offset) without loading whole file
      lines = []
      File.open(file, 'rb') do |f|
        f.each_line.with_index do |ln, idx|
          next if idx < start
          lines << (ln.chomp)
          break if lines.length >= limit
        end
      end
      lines.join("\n")
    when 'tail'
      # Efficiently collect lines from the end without loading the whole file.
      # We need limit + start lines from the end, then drop the first `start`
      needed = limit + start
      buffer = ''
      File.open(file, 'rb') do |f|
        f.seek(0, IO::SEEK_END)
        pos = f.pos
        # read backwards in blocks until we have enough newlines or we reached start
        while pos > 0 && buffer.count("\n") <= needed
          read_size = [pos, 8192].min
          pos -= read_size
          f.seek(pos, IO::SEEK_SET)
          buffer = f.read(read_size) + buffer
        end
      end

      # Split into lines. If the file ends with newline, split will give last element '' — using split("\n") gives predictable behaviour.
      arr = buffer.split("\n")
      # choose the last `needed` lines (or fewer if file smaller)
      start_index = [arr.length - needed, 0].max
      selected = arr[start_index, needed] || []
      # drop `start` lines from the front of the selected portion, then take `limit`
      result = (selected[start, limit] || [])
      result.join("\n")
    else
      raise ParameterException, "Unknown file_end must be head or tail: #{Log.fingerprint file_end}"
    end
  end

  desc <<-EOF
List all the files and subdirectories in a directory and returns the files and
directories separatedly, and optionaly some file stats like size, and
modification time.

Example: {files: ['foo', 'bar/bar'], directories: ['bar'], stats: {'foo' => {size: 100, mtime='2025-10-2 15:00:00'}}, 'bar/bar' => {size: 200, mtime='2025-10-3 15:30:10'}} }
  EOF
  input :directory, :path, 'Directory to list', nil, required: true
  input :recursive, :boolean, 'List recursively', true
  input :stats, :boolean, 'Return some stats for the files', false
  extension :json
  task :list_directory => :text do |directory,recursive,stats|
    directory = normalize directory
    raise ParameterException, "Directory not found: #{directory}" unless Open.exists?(directory)
    raise ParameterException, "Not a directory: #{directory}" unless Open.directory?(directory)
    files = if recursive
              Path.setup(directory).glob('**/*')
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
    normalize file
    raise ParameterException, "File not found: #{file}" unless Open.exists?(file)
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

  desc 'Return the current process working directory (PWD)'
  task :pwd => :string do
    Dir.pwd
  end

  export_exec :list_directory, :write, :read, :file_stats, :pwd
end
