module ComputerUse

  TMP_DIRS = Path.setup("tmp").find_all

  def self.get_allowed_paths(type)
    type_defaults = {
      exec_paths: %w(/bin /usr /lib /lib64 /etc).join(":"),
      allowed_paths: (TMP_DIRS + %w(/tmp ~/tmp)).join(":"),
      dirs: %w().join(":"),
      read_paths: %w().join(":"),
      thread: Thread.current['allowed_paths'],
      thread_read: Thread.current['allowed_read_paths']
    }
    
    IndiferentHash.setup(type_defaults)

    dir_str = Scout::Config.get(type, :ComputerUse, :computer_use, :sandbox, default: type_defaults[type], env: type.to_s.upcase)

    return [] if dir_str.nil?
    dirs = String === dir_str ? dir_str.split(/[,:]/) : dir_str
    dirs.collect{|dir| 
      dir = Path.setup(File.expand_path(dir))
      if dir.located?
        dir
      else
        dir.find_all
      end
    }.flatten
  end


  @root = Dir.pwd
  singleton_class.attr_accessor :root

  def self.allowed_paths
    dirs = get_allowed_paths(:allowed_paths) 
    dirs += get_allowed_paths(:dirs) 
    dirs += get_allowed_paths(:thread) 
    dirs
  end

  def self.allowed_read_paths
    dirs = get_allowed_paths(:allowed_read_paths)
    dirs += get_allowed_paths(:exec_paths)
    dirs += get_allowed_paths(:read_paths)
    dirs += get_allowed_paths(:thread_read) 
    dirs
  end

  helper :inside? do |directory,path|
    return path if File.expand_path(directory) == File.expand_path(path)

    if Open.exists?(path) || Open.directory?(path)
      return path if Open.realpath(directory) == Open.realpath(path)
      if Misc.path_relative_to(File.expand_path(Open.realpath(directory)), File.expand_path(Open.realpath(path))).nil?
        raise SandboxAccessViolation, "File #{path} not under #{directory}"
      end
    else
      if Misc.path_relative_to(File.expand_path(directory), File.expand_path(path)).nil?
        raise SandboxAccessViolation, "File #{path} not under #{directory}"
      end
    end
    return path
  end

  helper :normalize do |path, type=:read|
    path = '.' if path == '' || TrueClass === path
    path = "./#{path}" unless path.start_with?('/') || path.start_with?('./') || path.start_with?('~')

    begin
      inside?(ComputerUse.root, path)
    rescue 
      ComputerUse.allowed_paths.each do |dir|
        dir = File.expand_path(dir)
        dir = Path.setup dir unless Path === dir
        begin
          return inside?(dir, path)
        rescue 
          next
        end
      end

      ComputerUse.allowed_read_paths.each do |dir|
        dir = File.expand_path(dir)
        dir = Path.setup dir unless Path === dir
        begin
          return inside?(dir, path)
        rescue 
          next
        end
      end if type.to_s == 'read'

      if type.to_s == 'read'
        all_paths = [ComputerUse.root, ComputerUse.allowed_paths, ComputerUse.allowed_read_paths].flatten.compact.uniq
        raise SandboxAccessViolation, "Path #{path} not read allowed: #{all_paths}"
      else
        all_paths = [ComputerUse.root, ComputerUse.allowed_paths].flatten.compact.uniq
        raise SandboxAccessViolation, "Path #{path} not write allowed: #{all_paths}"
      end
    end
  end

  desc <<-EOF
Write a file.
  EOF
  input :path, :path, 'File to write', nil, required: true
  input :content, :text, 'Content to write into the file', nil, required: true
  task :write => :string do |file,content|
    file = normalize file, :write
    raise ParameterException, "File is a directory: #{file}" if Open.directory?(file)
    Open.write file, content
    "success writing to #{file}"
  end

  desc <<-EOF
Read a file. Don't specify a limit to read it complete. If you specify a limit specify a file_end which can be head or tail.
You may also specify start (line offset). For head start is 0-based from the beginning; for tail start is 0-based from the end (0 == last line).
  EOF
  input :path, :path, 'Path to the file to read', nil, required: true
  input :limit, :integer, 'Maximum number of lines to return from chosen end of the file'
  input :chars, :integer, 'Maximum number of chars to return from chosen end of the file'
  input :file_end, :select, 'Side of file to read', :head, select_options: %w(head tail)
  input :start, :integer, 'Line offset: for head -> 0-based from start; for tail -> 0-based from end (0 == last line)', 0
  task :read => :text do |file, limit, chars, file_end, start|
    file = normalize file

    raise ParameterException, "File not found #{file}" unless Open.exists?(file)
    raise ParameterException, 'File is really a directory, can not read' if Open.directory?(file)

    # no limit -> read full file (same behaviour as before)
    unless (limit && limit.to_i > 0) || (chars && chars.to_i > 0)
      next Open.read(file)
    end

    limit = limit.to_i
    raise ParameterException, "Wrong limit: #{Log.fingerprint limit}" if limit < 0

    chars = chars.to_i
    raise ParameterException, "Wrong chars limit: #{Log.fingerprint chars}" if chars < 0

    start = (start || 0).to_i
    raise ParameterException, "Wrong start: #{Log.fingerprint start}" if start < 0

    if limit > 0
      res = case file_end.to_s
            when '', 'head'
              # Read from the start (or from start offset) without loading whole file
              lines = []
              File.open(file, 'rb') do |f|
                f.each_line.with_index do |ln, idx|
                  next if idx < start
                  lines << (ln.chomp)
                  break if limit > 0 && lines.length >= limit
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
    else
      res = Open.read(file)
    end

      if chars && chars.to_i > 0
        if file_end == 'tail'
          res = res[-(chars+1)..-1]
        else
          res = res[0..chars-1]
        end
      end

      res
    end

    desc <<-EOF
List all the files and subdirectories in a directory and returns the files and
directories separatedly, and optionaly some file stats like size, and
modification time.

Example: {files: ['foo', 'bar/bar'], directories: ['bar'], stats: {'foo' => {size: 100, mtime='2025-10-2 15:00:00'}}, 'bar/bar' => {size: 200, mtime='2025-10-3 15:30:10'}} }
    EOF
    input :directory, :path, 'Directory to list. Regular expressions not allowed.', nil, required: true
    input :recursive, :boolean, 'List recursively', true
    input :stats, :boolean, 'Return some stats for the files', false
    task :list_directory => :json do |directory,recursive,stats|
      raise ParameterException, "Directory is a regular expression" if Regexp === directory
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

      info
    end

    desc <<-EOF
Return stats if a file.

Stats: size, modification time, binary or
not, number of lines (if not binary), etc

  EOF
  input :file, :path, 'File with stats to report', nil, required: true
  task :file_stats => :json do |file,root|
    normalize file
    raise ParameterException, "File not found: #{file}" unless Open.exists?(file)
    file = Path.setup(file)
    stats = {}
    stats[:type] = file.directory? ? :directory : :file
    if ! file.directory?
      stats[:binary] = false
      stats[:size] = Open.size(file)
      stats[:lines] = Open.read(file).split("\n").length
      stats[:mtime] = Open.mtime(file)
    end
    stats
  end

  export_exec :list_directory, :write, :read, :file_stats

  desc 'Return the current process working directory (PWD)'
  task :pwd => :string do
    Dir.pwd
  end

  # Delete task
  desc <<-EOF
Delete a file or directory. The path must be relative to the
`ComputerUse.root` directory, and deletion is performed with the same
path sanity checks as the read/write tasks.

If the target is a directory it is removed recursively.

  EOF
  input :file, :path, 'File or directory to delete', nil, required: true
  task :delete => :string do |file|
    file = normalize file, :write
    raise ParameterException, "File not found: #{file}" unless Open.exists?(file)
    raise ParameterException, "Root path cannot be deleted" if File.expand_path(file) == File.expand_path(ComputerUse.root)

    if Open.directory?(file)
      FileUtils.remove_dir(file, true)
      "deleted directory #{file}"
    else
      File.delete(file)
      "deleted file #{file}"
    end
  end

  # Copy task
  desc <<-EOF
Copy a file or directory. The target path must be relative to the
`ComputerUse.root` directory.

If the source is a directory it is copied recursively. There is
no need to create directories in the target, they will be created automatically
  EOF
  input :source, :path, 'File or directory to copy', nil, required: true
  input :target, :path, 'Target path', nil, required: true
  task :copy => :string do |source,target|
    source = normalize source, :read
    target = normalize target, :write
    raise ParameterException, "Source file not found: #{source}" unless Open.exists?(source)
    raise ParameterException, "Root path cannot be deleted" if File.expand_path(file) == File.expand_path(ComputerUse.root)

    Open.cp source, target
  end

  # Search for files within a directory whose content matches a query string.
  # The search is performed recursively on the supplied path (which must be a
  # subpath of ComputerUse.root).
  desc <<-EOF
  Search for files within a directory whose content matches a query string.

  Parameters:
  * **path** – Directory to start searching from.
  * **query** – String to look for in file contents. Only plain‑text files
    are considered; binary files are skipped.
  * **max_results** – Maximum number of matches to return. If not supplied, all
    matches will be returned.

  The task returns a JSON array of relative file paths (relative to
  ComputerUse.root). If no files match, an empty array is returned.
  EOF
  input :path, :path, 'Root directory to search', nil, required: true
  input :query, :string, 'String to search for in file contents', nil, required: true
  input :max_results, :integer, 'Maximum number of results to return', 10
  input :max_files, :integer, 'Maximum number of results to examine', 200
  task :search => :array do |path, query, max_results, max_files|
    path = normalize path
    raise ParameterException, "Directory not found: #{path}" unless Open.exists?(path)
    raise ParameterException, "Not a directory: #{path}" unless Open.directory?(path)
    raise ParameterException, "Empty query string" if query.nil? || query.empty?
    results = []
    max_results = max_results.to_i
    max_results = Float::INFINITY if max_results <= 0
    files = Path.setup(path).glob('**/*')

    raise ParameterException, "Too many files #{files.length} (maximum #{max_files})" if files.length > max_files

    TSV.traverse files, bar: self.progress_bar("Searching files") do |file|
      break if results.size >= max_results
      next if file.directory?
      next if Open.compressed?(file)
      begin
        content = file.read
      rescue
        next
      end
      next unless content.include?(query)
      results << file.relative_to(path)
    end
    results
  end

  export_exec :list_directory, :write, :read, :file_stats, :pwd, :copy, :delete, :search
end
