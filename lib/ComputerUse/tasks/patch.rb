require 'fileutils'
require 'scout'
module ComputerUse

  def self.convert_chatgpt_patch(patch_text)
    return '' if patch_text.nil?

    # Pass through real unified diffs untouched
    if patch_text =~ /^--- \S/ && patch_text =~ /^\+\+\+ \S/
      return patch_text.end_with?("\n") ? patch_text : patch_text + "\n"
    end

    root = Dir.pwd

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

    # Find exact consecutive match of lines in file
    find_match = lambda do |file_lines, target_lines|
      return nil if target_lines.empty?

      matches = []
      (0..file_lines.length - target_lines.length).each do |i|
        if file_lines[i, target_lines.length] == target_lines
          matches << i
        end
      end

      if matches.empty?
        raise ScoutException, "Could not locate hunk context in file"
      elsif matches.length > 1
        raise ScoutException, "Ambiguous hunk: multiple matches found"
      end

      matches.first
    end

    blocks = []
    current = nil
    in_code_fence = false

    patch_text.each_line do |raw|
      line = raw.chomp

      if line.start_with?("```")
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

    return patch_text + "\n" if blocks.empty?

    out = []

    blocks.each do |blk|
      rel = ensure_rel.call(blk[:path])
      a_name = "a/#{rel}"
      b_name = "b/#{rel}"
      body = blk[:body]

      case blk[:action]

        # ------------------------
        # ADD FILE
        # ------------------------
      when :add
        out << "--- /dev/null\n"
        out << "+++ #{b_name}\n"
        out << "@@ -0,0 +1,#{body.length} @@\n"
        body.each { |l| out << "+#{l}\n" }

        # ------------------------
        # DELETE FILE
        # ------------------------
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

        # ------------------------
        # UPDATE FILE
        # ------------------------
      when :update
        file_lines = read_file_lines.call(rel)

        out << "--- #{a_name}\n"
        out << "+++ #{b_name}\n"

        # Split into hunks
        hunks = []
        current_hunk = []

        body.each do |line|
          if line.start_with?('@@')
            hunks << current_hunk unless current_hunk.empty?
            current_hunk = [line]
          else
            current_hunk << line
          end
        end
        hunks << current_hunk unless current_hunk.empty?

        # If no @@ present → treat entire body as one contextual hunk
        if hunks.length == 1 && !hunks.first.first&.start_with?('@@')
          hunks = [["@@"]] + hunks
        end

        hunks.each do |hunk|
          header = hunk.first
          lines = hunk[1..] || []

          # If numeric unified header → preserve and verify counts
          if header =~ /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
            old_start = $1.to_i
            old_count = ($2 || "1").to_i
            new_start = $3.to_i
            new_count = ($4 || "1").to_i

            # Recompute actual counts
            computed_old = lines.count { |l| l.start_with?(' ') || l.start_with?('-') }
            computed_new = lines.count { |l| l.start_with?(' ') || l.start_with?('+') }

            old_count = computed_old
            new_count = computed_new

            out << "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@\n"

            lines.each do |l|
              if l.start_with?(' ', '+', '-')
                out << "#{l}\n"
              else
                out << " #{l}\n"
              end
            end

          else
            # Contextual @@ → must resolve position
            minus_lines = lines.select { |l| l.start_with?('-') }.map { |l| l[1..] }
            context_lines = lines.select { |l| l.start_with?(' ') }.map { |l| l[1..] }

            anchor = minus_lines.empty? ? context_lines : minus_lines

            if anchor.empty?
              raise ScoutException, "Cannot resolve hunk without context or deletions"
            end

            index = find_match.call(file_lines, anchor)

            old_start = index + 1
            old_count = lines.count { |l| l.start_with?(' ') || l.start_with?('-') }
            new_count = lines.count { |l| l.start_with?(' ') || l.start_with?('+') }

            out << "@@ -#{old_start},#{old_count} +#{old_start},#{new_count} @@\n"

            lines.each do |l|
              if l.start_with?(' ', '+', '-')
                out << "#{l}\n"
              else
                out << " #{l}\n"
              end
            end
          end
        end
      end
    end

    result = out.join
    result.end_with?("\n") ? result : result + "\n"
  end

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
    generated = ComputerUse.convert_chatgpt_patch(patch_text)
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
