module ComputerUse
  helper :convert_chatgpt_patch do |patch_text|
    filename = nil

    # First pass: turn ChatGPT markers into ---/+++ headers and keep hunks
    files = {}
    current = nil
    patch_text.each_line do |line|
      case line
      when /\A\*\*\* Update File: (.+)/
        filename = $1.strip
        files[filename] ||= []
        current = filename
        files[filename] << "--- #{filename}\n"
        files[filename] << "+++ #{filename}\n"
      when /\A\*\*\* Begin Patch/, /\A\*\*\* End Patch/
        # skip marker lines
      else
        files[current] << line if current
      end
    end

    # If we didn't detect any ChatGPT-style markers, return original text unchanged
    return patch_text if files.empty?

    # Helper to compute hunk ranges by reading original file and producing
    # a reasonable @@ header for hunks that lack one. The strategy is:
    # 1. Extract the old (lines starting with '-' or ' ') and new (lines with '+' or ' ') sequences.
    # 2. Try to find the old sequence as a contiguous block in the original file.
    # 3. If not found, try to locate any context (' ') line to estimate position.
    # 4. If still not found and the old sequence is empty (pure insertion), place the hunk
    #    at the end of the file (append) or beginning as a fallback.
    compute_hunk_header = lambda do |filename, hunk_lines|
      root = ComputerUse.root
      file_path = File.join(root, filename)
      original = File.exist?(file_path) ? File.read(file_path).each_line.map(&:chomp) : []

      # Normalize hunk_lines: keep leading char (+/-/space) and chomp content
      norm = hunk_lines.map do |l|
        prefix = l[0] || ' '
        content = (l[1..-1] || '').chomp
        [prefix, content]
      end

      old_seq = norm.select { |p, _| p == '-' || p == ' ' }.map { |_, c| c }
      new_seq = norm.select { |p, _| p == '+' || p == ' ' }.map { |_, c| c }

      old_len = old_seq.length
      new_len = new_seq.length

      # Try to find exact match of old_seq in original
      old_start = nil
      if old_len > 0 and original.length >= old_len
        0.upto(original.length - old_len) do |i|
          if original[i, old_len] == old_seq
            old_start = i + 1
            break
          end
        end
      end

      # If not found, try to use any context line (' ') to approximate position
      if old_start.nil? and original.length > 0
        context_lines = norm.select { |p, _| p == ' ' }.map { |_, c| c }
        context_lines.each do |context|
          idx = original.index(context)
          if idx
            old_start = idx + 1
            break
          end
        end
      end

      # Fallbacks:
      if old_start.nil?
        if old_len == 0
          # pure addition: place after end of file (append)
          old_start = original.length + 1
        else
          # default to start of file
          old_start = 1
        end
      end

      # Compute new_start: typically equal to old_start
      new_start = old_start

      # Build range strings
      old_range = if old_len == 0
                    # represent as "N,0" where N is the previous line number (0 allowed)
                    prev = [old_start - 1, 0].max
                    "#{prev},0"
                  elsif old_len == 1
                    old_start.to_s
                  else
                    "#{old_start},#{old_len}"
                  end

      new_range = new_len == 1 ? new_start.to_s : "#{new_start},#{new_len}"

      "@@ -#{old_range} +#{new_range} @@
"
    end
    # Second pass: for each file block, ensure hunks have proper @@ headers
    out_lines = []
    files.each do |fname, block_lines|
      i = 0
      while i < block_lines.length
        line = block_lines[i]
        # If we encounter an existing @@ header, make sure it's complete; otherwise keep it
        if line.start_with?('@@')
          # crude check: if header doesn't contain '-' and '+' ranges, recompute
          if line !~ /-\d/ || line !~ /\+\d/
            # collect hunk fragment after this line
            hstart = i + 1
            hunk = []
            while hstart < block_lines.length && block_lines[hstart] =~ /^[ +-]/ && block_lines[hstart] !~ /\A--- / && block_lines[hstart] !~ /\A\+\+\+ /
              hunk << block_lines[hstart]
              hstart += 1
            end
            header = compute_hunk_header.call(fname, hunk)
            out_lines << header
            # also append the hunk lines after the computed header
            hunk.each { |hl| out_lines << hl }
            i = hstart
            next
          else
            out_lines << line
            i += 1
            next
          end
        end

        # If this line looks like the start of a hunk (space/+/-) and the previous
        # output line is not an @@ header, insert a computed header
        if line =~ /^[ +-]/ && line !~ /\A--- / && line !~ /\A\+\+\+ /
          prev = out_lines.last
          unless prev && prev.start_with?('@@')
            hstart = i
            hunk = []
            while hstart < block_lines.length && block_lines[hstart] =~ /^[ +-]/ && block_lines[hstart] !~ /\A--- / && block_lines[hstart] !~ /\A\+\+\+ /
              hunk << block_lines[hstart]
              hstart += 1
            end
            header = compute_hunk_header.call(fname, hunk)
            out_lines << header
            # append the hunk lines
            hunk.each { |hl| out_lines << hl }
            i = hstart
            next
          end
        end

        # Normal line (file header like ---/+++ or others)
        out_lines << line
        i += 1
      end
    end

    out_lines.join
  end

  desc <<-EOF
Apply a patch to the files under the current working directory #{Dir.pwd} using the patch command.

Inputs:
- patch: the patch content (unified diff or other format accepted by the `patch` utility; ChatGPT style patches will be converted)
- strip: the -pN argument for the patch command (defaults to 0)
- dry_run: if true, runs patch with --dry-run (check only, do not modify files)

Returns a JSON object with keys stdout, stderr and exit_status.
  EOF
  input :patch, :text, 'Patch content', nil, required: true
  input :strip, :integer, 'Number for patch -pN (strip count)', 0
  input :dry_run, :boolean, 'If true, perform a dry-run (do not apply)', false
  extension :json
  task :patch => :text do |patch_text, strip, dry_run, root|
    patch_text ||= ''
    strip = (strip || 0).to_i
    dry_run = !!dry_run
    
    patch_text = convert_chatgpt_patch patch_text


    Dir.chdir(ComputerUse.root) do
      # Build command args; pass as an array to avoid shell quoting issues.
      # Include '-' so patch reads the patch from stdin explicitly.
      cmd = ["-p#{strip}"]
      cmd << '--dry-run' if dry_run

      # Pass the args array directly. Provide the patch content as stdin.
      cmd_json :patch, cmd, in: patch_text
    end
  end

  export_exec :patch
end
