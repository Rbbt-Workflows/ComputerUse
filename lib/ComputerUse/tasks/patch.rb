require 'fileutils'
module ComputerUse

  helper :convert_chatgpt_patch do |patch_text|
    return '' if patch_text.nil?

    # If already unified diff, return as-is (normalized newline)
    if patch_text =~ /^--- \S/ && patch_text =~ /^\+\+\+ \S/
      return patch_text.end_with?("\n") ? patch_text : patch_text + "\n"
    end

    root = ComputerUse.root
    blocks = []
    current = nil
    in_code_fence = false

    patch_text.each_line do |raw_line|
      line = raw_line.dup

      if line.start_with?('```')
        in_code_fence = !in_code_fence
        next
      end

      case line
      when /\A\*\*\*\s*Begin Patch/i
        next
      when /\A\*\*\*\s*End Patch/i
        current = nil
      when /\A\*\*\*\s*Update File:\s*(.+)/i
        current = { action: :update, path: $1.strip, body: [] }
        blocks << current
      when /\A\*\*\*\s*Add File:\s*(.+)/i
        current = { action: :add, path: $1.strip, body: [] }
        blocks << current
      when /\A\*\*\*\s*Delete File:\s*(.+)/i
        current = { action: :delete, path: $1.strip, body: [] }
        blocks << current
      else
        next if current.nil? || in_code_fence
        current[:body] << line
      end
    end

    # If nothing parsed, return original
    if blocks.empty?
      return patch_text.end_with?("\n") ? patch_text : patch_text + "\n"
    end

    ensure_rel = lambda do |p|
      p = p.to_s.strip
      if p.start_with?('/')
        if p.start_with?(root.to_s)
          p = p.sub(/^#{Regexp.escape(root.to_s)}\/?/, '')
        else
          p = p.sub(%r{^/+}, '')
        end
      end
      p = p.sub(%r{^\./+}, '')
      raise ScoutException, "Unsafe path: #{p}" if p.include?('..')
      p
    end

    read_file_lines = lambda do |rel|
      path = File.join(root, rel)
      File.exist?(path) ? File.read(path).lines.map(&:chomp) : []
    end

    valid_hunk_header = lambda do |line|
      line =~ /^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@/
    end

    compute_hunk_counts = lambda do |lines|
      old_count = lines.count { |l| l.start_with?(' ') || l.start_with?('-') }
      new_count = lines.count { |l| l.start_with?(' ') || l.start_with?('+') }
      [old_count, new_count]
    end

    out = []

    blocks.each do |blk|
      action = blk[:action]
      rel = ensure_rel.call(blk[:path])
      a_name = "a/#{rel}"
      b_name = "b/#{rel}"
      body = blk[:body].map(&:rstrip)

      case action

        # -------------------------
        # ADD FILE
        # -------------------------
      when :add
        out << "--- /dev/null\n"
        out << "+++ #{b_name}\n"

        new_lines = body
        out << "@@ -0,0 +1,#{new_lines.length} @@\n"
        new_lines.each { |l| out << "+#{l}\n" }

        # -------------------------
        # DELETE FILE
        # -------------------------
      when :delete
        old_lines = read_file_lines.call(rel)

        out << "--- #{a_name}\n"
        out << "+++ /dev/null\n"

        if old_lines.empty?
          out << "@@ -0,0 +0,0 @@\n"
        else
          out << "@@ -1,#{old_lines.length} +0,0 @@\n"
          old_lines.each { |l| out << "-#{l}\n" }
        end

        # -------------------------
        # UPDATE FILE
        # -------------------------
      when :update
        old_lines = read_file_lines.call(rel)

        out << "--- #{a_name}\n"
        out << "+++ #{b_name}\n"

        # If body already contains valid hunks, pass through safely
        if body.any? { |l| valid_hunk_header.call(l) }

          i = 0
          while i < body.length
            line = body[i]

            if valid_hunk_header.call(line)
              out << "#{line}\n"
              i += 1

              hunk_lines = []

              while i < body.length && !valid_hunk_header.call(body[i])
                hunk_lines << body[i]
                i += 1
              end

              # Ensure hunk counts are correct
              old_count, new_count = compute_hunk_counts.call(hunk_lines)

              # Rewrite header with correct counts if needed
              header = out.pop
              header =~ /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/
              old_start = $1.to_i
              new_start = $2.to_i
              header = "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@\n"
              out << header

              hunk_lines.each do |l|
                if l.start_with?(' ', '+', '-')
                  out << "#{l}\n"
                else
                  out << " #{l}\n"
                end
              end

            else
              # No valid hunks → treat as full replacement
              new_lines = body
              old_count = old_lines.length
              new_count = new_lines.length

              out << "@@ -#{old_count.zero? ? '0,0' : "1,#{old_count}"} +#{new_count.zero? ? '0,0' : "1,#{new_count}"} @@\n"

              old_lines.each { |l| out << "-#{l}\n" }
              new_lines.each { |l| out << "+#{l}\n" }

              break
            end
          end

        else
          # Full replacement
          new_lines = body
          old_count = old_lines.length
          new_count = new_lines.length

          out << "@@ -#{old_count.zero? ? '0,0' : "1,#{old_count}"} +#{new_count.zero? ? '0,0' : "1,#{new_count}"} @@\n"

          old_lines.each { |l| out << "-#{l}\n" }
          new_lines.each { |l| out << "+#{l}\n" }
        end
      end
    end

    result = out.join
    result.end_with?("\n") ? result : result + "\n"
  end

  #helper :convert_chatgpt_patch do |patch_text|
  #  return '' if patch_text.nil?
  #  if patch_text =~ /^--- \S/ && patch_text =~ /^\+\+\+ \S/
  #    return patch_text.end_with?("\n") ? patch_text : patch_text + "\n"
  #  end
  #  root = ComputerUse.root
  #  blocks = []
  #  current = nil
  #  in_code_fence = false
  #  patch_text.each_line do |raw_line|
  #    line = raw_line.dup
  #    if line.start_with?('```')
  #      in_code_fence = !in_code_fence
  #      next
  #    end
  #    case line
  #    when /\A\*\*\*\s*Begin Patch/i
  #    when /\A\*\*\*\s*End Patch/i
  #      current = nil
  #    when /\A\*\*\*\s*Update File:\s*(.+)/i
  #      path = $1.strip
  #      current = { action: :update, path: path, body: [] }
  #      blocks << current
  #    when /\A\*\*\*\s*Add File:\s*(.+)/i
  #      path = $1.strip
  #      current = { action: :add, path: path, body: [] }
  #      blocks << current
  #    when /\A\*\*\*\s*Delete File:\s*(.+)/i
  #      path = $1.strip
  #      current = { action: :delete, path: path, body: [] }
  #      blocks << current
  #    else
  #      next if current.nil?
  #      next if in_code_fence
  #      current[:body] << line
  #    end
  #  end
  #  if blocks.empty?
  #    return patch_text.end_with?("\n") ? patch_text : patch_text + "\n"
  #  end
  #  ensure_rel = lambda do |p|
  #    p = p.to_s.strip
  #    if p.start_with?('/')
  #      if p.start_with?(root.to_s)
  #        p = p.sub(/^#{Regexp.escape(root.to_s)}\/?/, '')
  #      else
  #        p = p.sub(%r{^/+}, '')
  #      end
  #    end
  #    p = p.sub(%r{^\./+}, '')
  #    raise ScoutException, "Unsafe path: #{p}" if p.include?('..')
  #    p
  #  end
  #  read_file_lines = lambda do |rel|
  #    path = File.join(root, rel)
  #    File.exist?(path) ? File.read(path).each_line.map { |l| l.chomp } : []
  #  end
  #  looks_like_hunks = lambda do |lines|
  #    lines.any? { |l| l.start_with?(' ', '+', '-', '@@') } ||
  #      (lines.any? { |l| l.start_with?('--- ') } && lines.any? { |l| l.start_with?('+++ ') })
  #  end
  #  out = []
  #  blocks.each do |blk|
  #    action = blk[:action]
  #    rel = ensure_rel.call(blk[:path])
  #    a_name = "a/#{rel}"
  #    b_name = "b/#{rel}"
  #    body = blk[:body]
  #    while body.last && body.last.strip == ''
  #      body.pop
  #    end
  #    case action
  #    when :add
  #      new_lines = body.map { |l| l.chomp }
  #      out << "--- /dev/null\n"
  #      out << "+++ #{b_name}\n"
  #      out << "@@ -0,0 +1,#{new_lines.length} @@\n"
  #      new_lines.each { |l| out << "+#{l}\n" }
  #    when :delete
  #      old_lines = read_file_lines.call(rel)
  #      out << "--- #{a_name}\n"
  #      out << "+++ /dev/null\n"
  #      if old_lines.empty?
  #        out << "@@ -0,0 +0,0 @@\n"
  #      else
  #        out << "@@ -1,#{old_lines.length} +0,0 @@\n"
  #        old_lines.each { |l| out << "-#{l}\n" }
  #      end
  #    when :update
  #      if looks_like_hunks.call(body)
  #        out << "--- #{a_name}\n"
  #        out << "+++ #{b_name}\n"
  #        i = 0
  #        while i < body.length
  #          line = body[i]
  #          if line.start_with?('@@')
  #            if line !~ /-\d/ || line !~ /\+\d/
  #              old_lines = read_file_lines.call(rel)
  #              new_lines = []
  #              body.each { |l2| new_lines << l2[1..-1].to_s.chomp if l2.start_with?('+', ' ') }
  #              old_len = old_lines.length
  #              new_len = new_lines.length
  #              out << "@@ -1,#{old_len} +1,#{new_len} @@\n"
  #            else
  #              out << (line.end_with?("\n") ? line : "#{line}\n")
  #            end
  #            i += 1
  #            while i < body.length && !body[i].start_with?('--- ') && !body[i].start_with?('+++ ') && !body[i].start_with?('@@')
  #              l = body[i]
  #              if l.start_with?(' ', '+', '-')
  #                out << (l.end_with?("\n") ? l : "#{l}\n")
  #              else
  #                out << " #{l.chomp}\n"
  #              end
  #              i += 1
  #            end
  #          elsif line =~ /^[ +\-]/
  #            old_lines = read_file_lines.call(rel)
  #            new_lines = []
  #            j = i
  #            while j < body.length && body[j] !~ /^@@/ && body[j] !~ /^--- / && body[j] !~ /^\+\+\+ /
  #              l = body[j]
  #              if l.start_with?('+')
  #                new_lines << l[1..-1].to_s.chomp
  #              elsif l.start_with?(' ')
  #                new_lines << l[1..-1].to_s.chomp
  #              end
  #              j += 1
  #            end
  #            out << "@@ -1,#{old_lines.length} +1,#{new_lines.length} @@\n"
  #            old_lines.each { |ol| out << "-#{ol}\n" }
  #            new_lines.each { |nl| out << "+#{nl}\n" }
  #            i = j
  #          else
  #            i += 1
  #          end
  #        end
  #      else
  #        new_lines = body.map { |l| l.chomp }
  #        old_lines = read_file_lines.call(rel)
  #        out << "--- #{a_name}\n"
  #        out << "+++ #{b_name}\n"
  #        out << "@@ -#{old_lines.empty? ? '0,0' : "1,#{old_lines.length}"} +#{new_lines.empty? ? '0,0' : "1,#{new_lines.length}"} @@\n"
  #        old_lines.each { |l| out << "-#{l}\n" }
  #        new_lines.each { |l| out << "+#{l}\n" }
  #      end
  #    end
  #  end
  #  text = out.join
  #  return text.end_with?("\n") ? text : text + "\n"
  #end

  desc <<-EOF
Apply a patch to files under the repository root using the system 'patch' utility.

Enhancements:
- Converts ChatGPT-style patches into canonical unified diffs with a/ and b/ headers
- Auto-detects -p (strip) level via --dry-run if not specified
- Returns structured diagnostics, including generated_patch, used_strip and tried_strips
- Optional apply_direct fallback to write files directly when the patch utility fails and the
  content appears to be full-file content (not a diff)

Inputs:
- patch: the patch content (unified diff or ChatGPT-style); required
- strip: integer -pN override (auto-detected if nil)
- dry_run: if true, checks only (does not modify files)
- apply_direct: if true, attempt a direct apply fallback on failure

Returns a JSON object with keys:
- stdout, stderr, exit_status (from the final attempt)
- generated_patch (the unified diff text we produced)
- applied (boolean)
- applied_directly (boolean)
- used_strip (integer or nil)
- tried_strips ([{strip, stdout, stderr, exit_status}])
- suggestion (string)
  EOF
  input :patch, :text, 'Patch content', nil, required: true
  input :strip, :integer, 'Number for patch -pN (strip count). If nil, auto-detect.', nil
  input :dry_run, :boolean, 'If true, perform a dry-run (do not modify files)', false
  input :apply_direct, :boolean, 'If true, fallback to direct file writes if patch fails', false
  extension :json
  task :patch => :text do |patch_text, strip, dry_run, apply_direct|
    patch_text ||= ''
    dry_run = !!dry_run
    apply_direct = !!apply_direct

    file('original.patch').write patch_text
    generated = convert_chatgpt_patch(patch_text)
    tmp_patch = file('patch.diff')
    tmp_patch.write generated

    tried = []
    used_strip = nil
    malformed = false
    final = { stdout: '', stderr: '', exit_status: 1 }

    Dir.chdir(ComputerUse.root) do
      candidate_strips = strip.nil? || strip.to_i == 0 ? [1,0,2,3,4] : [strip.to_i]

      candidate_strips.each do |p|
        args = ["-p#{p}", '--dry-run', '-i', tmp_patch]
        res = cmd_json(:patch, args)
        tried << { strip: p, stdout: res[:stdout], stderr: res[:stderr], exit_status: res[:exit_status] }
        if res[:exit_status].to_i == 0
          used_strip = p
          final = res
          break
        elsif res[:stderr].include? "malformed"
          used_strip = p
          malformed = true
          break
        end
      end

      # If the first successful strip is 0 but diff uses b/ prefixes, prefer p=1 when it also works
      if used_strip == 0 && generated.include?("\n+++ b/")
        test_p1 = cmd_json(:patch, ["-p1", '--dry-run', '-i', tmp_patch])
        if test_p1[:exit_status].to_i == 0
          used_strip = 1
          final = test_p1
          tried << { strip: 1, stdout: test_p1[:stdout], stderr: test_p1[:stderr], exit_status: test_p1[:exit_status] }
        end
      end

      if used_strip.nil?
        suggestion = 'Could not auto-detect -p. Review tried_strips, verify paths in generated_patch, or specify strip explicitly.'
        applied_directly = false
        if apply_direct
          begin
            applied_directly = false
            root = ComputerUse.root
            blocks = []
            current = nil
            in_code_fence = false
            patch_text.each_line do |raw_line|
              line = raw_line.dup
              if line.start_with?('```')
                in_code_fence = !in_code_fence
                next
              end
              case line
              when /\A\*\*\*\s*Begin Patch/i
              when /\A\*\*\*\s*End Patch/i
                current = nil
              when /\A\*\*\*\s*Update File:\s*(.+)/i
                current = { action: :update, path: $1.strip, body: [] }
                blocks << current
              when /\A\*\*\*\s*Add File:\s*(.+)/i
                current = { action: :add, path: $1.strip, body: [] }
                blocks << current
              when /\A\*\*\*\s*Delete File:\s*(.+)/i
                current = { action: :delete, path: $1.strip, body: [] }
                blocks << current
              else
                next if current.nil? || in_code_fence
                current[:body] << line
              end
            end
            all_plain = blocks.any? && blocks.all? do |blk|
              body = blk[:body]
              body.none? { |l| l.start_with?('@@', '+', '-', '--- ', '+++ ') }
            end
            if all_plain
              blocks.each do |blk|
                rel = blk[:path]
                rel = rel.sub(%r{^/+}, '')
                raise ScoutException, "Unsafe path: #{rel}" if rel.include?('..')
                abs = File.join(root, rel)
                FileUtils.mkdir_p File.dirname(abs)
                case blk[:action]
                when :add, :update
                  content = blk[:body].join
                  if File.exist?(abs)
                    backup = abs + ".bak.#{Time.now.to_i}"
                    FileUtils.cp abs, backup
                  end
                  tmp = abs + ".tmp.#{Process.pid}"
                  File.open(tmp, 'wb') { |f| f.write(content) }
                  FileUtils.mv tmp, abs
                  applied_directly = true
                when :delete
                  if File.exist?(abs)
                    backup = abs + ".bak.#{Time.now.to_i}"
                    FileUtils.cp abs, backup
                    FileUtils.rm_f abs
                    applied_directly = true
                  else
                    applied_directly = true
                  end
                end
              end
            end
          rescue => e
            tried << { strip: 'apply_direct', stdout: '', stderr: e.message, exit_status: 1 }
            applied_directly = false
          end
        end
        next {
          exit_status: final[:exit_status],
          stdout: final[:stdout],
          stderr: final[:stderr],
          generated_patch: generated,
          tried_strips: tried,
          used_strip: used_strip,
          applied: false,
          applied_directly: applied_directly,
          suggestion: suggestion
        }.to_json
      end

      if dry_run
        next {
          exit_status: final[:exit_status],
          stdout: final[:stdout],
          stderr: final[:stderr],
          generated_patch: generated,
          tried_strips: tried,
          used_strip: used_strip,
          applied: false,
          applied_directly: false,
          suggestion: 'Dry run OK. Re-run with dry_run: false to apply.'
        }.to_json
      end

      apply_res = cmd_json(:patch, ["-p#{used_strip}", '-i', tmp_patch])
      next {
        exit_status: apply_res[:exit_status],
        stdout: apply_res[:stdout],
        stderr: apply_res[:stderr],
        generated_patch: generated,
        tried_strips: tried,
        used_strip: used_strip,
        applied: apply_res[:exit_status].to_i == 0,
        applied_directly: false,
        suggestion: apply_res[:exit_status].to_i == 0 ? 'Applied successfully.' : 'Patch failed on apply. Inspect stderr and generated_patch.'
      }.to_json
    end
  end

  export_exec :patch
end
