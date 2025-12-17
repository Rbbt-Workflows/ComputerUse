module ComputerUse
  input :pdf, :path, "Pdf file", nil, required: true
  extension :md
  task pdf2md_full: :text do |pdf|
    CMD.cmd(:docling, "'#{pdf}' --output '#{self.files_dir}'")
    raise ParameterException, "Nothing produced" if files.empty?
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
    if Open.remote?(html)
      begin
        html = Open.open(html)
      rescue => e
        raise ScoutException, e.message
      end
    end
    CMD.cmd(:html2markdown, in: html)
  end

  input :text, :text, 'Text in Markdown'
  input :strategy, :select, 'Chunking strategy', :paragraph, select_options: %w(paragraph sentences sliding)
  input :chunk_words, :integer, 'How many words per chunk in the sliding window', 50
  input :overlap, :integer, 'How many words of overlap  in the sliding window', 10
  task excerpts: :array do |text,strategy,chunk_words,overlap|
    text = text.load if Step === text

    # sanitize text
    text = text.gsub("\r", "")

    excerpts = []

    case strategy.to_s
    when 'paragraph'
      # paragraphs separated by blank lines; trim and drop very short paragraphs
      paragraphs = text.split(/\n{2,}/).map(&:strip).reject { |p| p.length < 40 }
      # Optionally further split long paragraphs into chunks of ~chunk_words words
      paragraphs.each do |p|
        words = p.split
        if words.length <= chunk_words
          excerpts << p
        else
          i = 0
          while i < words.length
            slice = words[i, chunk_words].join(' ')
            excerpts << slice
            i += (chunk_words - overlap)
          end
        end
      end

    when 'sliding'
      # sliding window over words
      words = text.split
      i = 0
      while i < words.length
        slice = words[i, chunk_words].join(' ')
        excerpts << slice
        i += (chunk_words - overlap)
      end

    when 'sentences'
      # naive sentence split; group sentences until approx chunk_words reached
      sentences = text.scan(/[^\.!?]+[\.!?]*/m).map(&:strip).reject(&:empty?)
      buffer = []
      bw = 0
      sentences.each do |s|
        sw = s.split.length
        if bw + sw <= chunk_words || buffer.empty?
          buffer << s
          bw += sw
        else
          excerpts << buffer.join(' ')
          buffer = [s]
          bw = sw
        end
      end
      excerpts << buffer.join(' ') unless buffer.empty?

    else
      # fallback: return entire document
      excerpts = [text]
    end

    # deduplicate near-identical excerpts and trim whitespace
    excerpts.map! { |e| e.strip }
    excerpts.uniq!

    ids = []
    excerpts.each do |excerpt|
      id = Misc.digest excerpt
      file(id).write excerpt
      ids << id
    end

    ids
  end

  dep :excerpts
  input :embed_model, :string, "Embedding model", 'mxbai-embed-large', required: false
  extension :rag
  task :rag => :binary  do |embed_model|
    require 'scout/llm/rag'
    job = step(:excerpts)
    ids = job.load

    embeddings = ids.collect do |id|
      file = job.file id
      LLM.embed(file.read, model: embed_model)
    end

    rag = LLM::RAG.index(embeddings)


    rag.save_index(self.tmp_path)
  end

  dep :rag
  input :prompt, :text, 'Text to match', nil, required: true
  input :num, :integer, 'Number of matches to return', 3
  task query: :json do |prompt,num|
    require 'scout/llm/rag'
    job = step(:excerpts)
    ids = job.load

    embed_model = recursive_inputs[:embed_model]
    value = LLM.embed(prompt, model: embed_model)

    rag = LLM::RAG.load(step(:rag).join.path, value.length)

    indices, scores = rag.search_knn(value, num)
    set_info :scores, scores
    ids.values_at(*indices).collect do |id|
      job.file(id).read
    end
  end

  dep :pdf2md
  task_alias :pdf_query, self, :query, text: :pdf2md

  dep :html2md
  task_alias :html_query, self, :query, text: :html2md

  export :pdf2md_full
  export :pdf2md
  export :html2md
  export :pdf_query
  export :html_query
end
