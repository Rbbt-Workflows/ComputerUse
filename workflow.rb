require 'scout'
module ComputerUse
  MEMORY = Scout.Memory.find(:lib)

  extend Workflow

  task current_time: :string do
    Time.now.to_s
  end
  export_exec :current_time

  input :dir, :path, "Directory", nil, required: true
  input :recursive, :boolean, "List recursively with -R", false
  desc "Use the ls tool to list directories, defaults to -la"
  task :list_files => :string do |dir,recursive|
    if recursive
      CMD.cmd(:ls, "-la '#{dir}'")
    else
      CMD.cmd(:ls, "-laR '#{dir}'")
    end
  end

  input :path, :path, "File path", nil, required: true
  input :max, :integer, "Show only the top max lines. All if set to 0 ", 0
  desc "Use the cat tool to get the content of a file, or use head -n $max if max is not 0"
  task :read_file => :string do |filename,max|
    if max.to_i == 0
      CMD.cmd(:cat, "'#{filename}'")
    else
      CMD.cmd(:head, "-n #{max} '#{filename}'")
    end
  end

  input :path, :path, "File path", nil, required: true
  input :content, :string, "Content of the file"
  desc "Write a file, the path should be relative to the current directory or an exception will be raised"
  task :write_file => :string do |filename,content|
    filename = './' + filename unless Path.located?(filename) || filename.start_with?('.')
    filename = filename.find if Path === filename

    if ! Misc.path_relative_to?(Dir.pwd, File.expand_path(filename))
      raise "Path not relative to PWD"
    else
      Open.write filename, content
      "saved #{filename}"
    end
  end
  export :list_files, :read_file, :write_file

  input :pdf, :path, "Pdf file", nil, required: true
  extension :md
  task pdf2md_full: :text do |pdf|
    CMD.cmd(:docling, "#{pdf} --output #{self.files_dir}")
    Open.mv file(files.first), self.tmp_path
    nil
  end

  dep :pdf2md_full
  extension :md
  task pdf2md_no_images: :text do
    text = step(:pdf2md_full).load
    text.split("\n").reject do |line|
      line.start_with?('![Image]')
    end * "\n"
  end

  task_alias :pdf2md, ComputerUse, :pdf2md_no_images

  input :html, :text, "HTML code, or url", nil, required: true
  task html2md: :text do |html|
    html = Open.open(html) if Open.remote?(html)
    CMD.cmd(:html2markdown, in: html)
  end
end
