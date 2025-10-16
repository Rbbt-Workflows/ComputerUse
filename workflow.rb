require 'scout'
module ComputerUse
  MEMORY = Scout.Memory.find(:lib)

  extend Workflow

  task current_time: :string do
    Time.now.to_s
  end

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

  export_exec :current_time
  export :pdf2md_full
  export :pdf2md
end
