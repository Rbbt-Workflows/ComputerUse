require 'fileutils'
module ComputerUse
  # Convert a ChatGPT-style patch into a canonical unified diff with a/ and b/ headers.
  # Also handles simple cases of Add/Delete/Update file markers and code fences.
  #
  # Behaviour:
  # - Recognizes the following markers:
  #   *** Begin Patch / *** End Patch
  #   *** Update File: <path>
  #   *** Add File: <path>
  #   *** Delete File: <path>
  # - Produces canonical headers:
  #   --- a/<path> / +++ b/<path> for updates
  #   --- /dev/null / +++ b/<path> for additions
  #   --- a/<path> / +++ /dev/null for deletions
  # - For blocks that do not look like unified hunks (no lines prefixed with +, -, or space),
  #   synthesizes a single 0-context hunk replacing the entire file.
  helper :convert_chatgpt_patch do |patch_text|
    return '' if patch_text.nil?

    # If the input already looks like a unified diff with ---/+++ headers, keep it
    if patch_text =~ /^--- \S/ && patch_text =~ /^\+\+\+ \S/
      # Ensure final newline
      return patch_text.end_with?("\n") ? patch_text : patch_text + "\n"
    end

    root = ComputerUse.root

    # Parse ChatGPT markers
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
        # noop
      when /\A\*\*\*\s*End Patch/i
        current = nil
      when /\A\*\*\*\s*Update File:\s*(.+)/i
        path = $1.strip
        current = { action: :update, path: path, body: [] }
        blocks << current
      when /\A\*\*\*\s*Add File:\s*(.+)/i
        path = $1.strip
        current = { action: :add, path: path, body: [] }
        blocks << current
      when /\A\*\*\*\s*Delete File:\s*(.+)/i
        path = $1.strip
        current = { action: :delete, path: path, body: [] }
        blocks << current
      else
        next if current.nil?
        # Skip leading fenced code block markers and any trailing markdown noise
        next if in_code_fence
        current[:body] << line
      end
    end

    # If no ChatGPT markers detected, return original text
    if blocks.empty?
      return patch_text.end_with?("\n") ? patch_text : patch_text + "\n"
    end

    # Helper utilities
    ensure_rel = lambda do |p|
      p = p.to_s.strip
      # normalize absolute paths to be relative to root when possible
      if p.start_with?('/')
        # try to strip ComputerUse.root prefix if present
        if p.start_with?(root.to_s)
          p = p.sub(/^#{Regexp.escape(root.to_s)}\/?/, '')
        else
          # strip leading '/'
          p = p.sub(%r{^/+}, '')
        end
      end
      p = p.sub(%r{^\./+}, '') # drop leading './'
      # collapse dangerous paths
      raise ScoutException, "Unsafe path: #{p}" if p.include?('..')
      p
    end

    read_file_lines = lambda do |rel|
      path = File.join(root, rel)
      File.exist?(path) ? File.read(path).each_line.map { |l| l.chomp } : []
    end

    looks_like_hunks = lambda do |lines|
      lines.any? { |l| l.start_with?(' ', '+', '-', '@@') } ||
        (lines.any? { |l| l.start_with?('--- ') } && lines.any? { |l| l.start_with?('+++ ') })
    end

    # Build canonical diff
    out = []

    blocks.each do |blk|
      action = blk[:action]
      rel = ensure_rel.call(blk[:path])
      a_name = "a/#{rel}"
      b_name = "b/#{rel}"

      body = blk[:body]

      # Trim trailing blank lines commonly added by LLMs
      while body.last && body.last.strip == ''
        body.pop
      end

      case action
      when :add
        new_lines = body.map { |l| l.chomp }
        out << "--- /dev/null\n"
        out << "+++ #{b_name}\n"
        out << "@@ -0,0 +1,#{new_lines.length} @@\n"
        new_lines.each { |l| out << "+#{l}\n" }
      when :delete
        old_lines = read_file_lines.call(rel)
        out << "--- #{a_name}\n"
        out << "+++ /dev/null\n"
        if old_lines.empty?
          # Nothing to delete; still produce a minimal hunk for consistency
          out << "@@ -0,0 +0,0 @@\n"
        else
          out << "@@ -1,#{old_lines.length} +0,0 @@\n"
          old_lines.each { |l| out << "-#{l}\n" }
        end
      when :update
        # If body already looks like hunks, we adapt headers; otherwise synthesize full-file replacement
        if looks_like_hunks.call(body)
          # Ensure headers exist and use canonical a/ and b/
          out << "--- #{a_name}\n"
          out << "+++ #{b_name}\n"

          # Copy hunks, inserting a header if missing
          # Gather hunk lines following the first line that starts with space/+/- if there is no @@ header yet
          i = 0
          while i < body.length
            line = body[i]
            if line.start_with?('@@')
              # Ensure it contains both - and + ranges; otherwise we will recompute roughly
              if line !~ /-\d/ || line !~ /\+\d/
                # recompute using entire block as context (approximate)
                old_lines = read_file_lines.call(rel)
                new_lines = []
                # Extract added and context lines as a rough new version when '+' or ' '
                body.each { |l2| new_lines << l2[1..-1].to_s.chomp if l2.start_with?('+', ' ') }
                old_len = old_lines.length
                new_len = new_lines.length
                out << "@@ -1,#{old_len} +1,#{new_len} @@\n"
              else
                out << (line.end_with?("\n") ? line : "#{line}\n")
              end
              i += 1
              # copy following lines until next header or file header
              while i < body.length && !body[i].start_with?('--- ') && !body[i].start_with?('+++ ') && !body[i].start_with?('@@')
                l = body[i]
                if l.start_with?(' ', '+', '-')
                  # Ensure each hunk line has a newline; avoid operator precedence pitfalls
                  out << (l.end_with?("\n") ? l : "#{l}\n")
                else
                  # Lines without prefix inside a hunk: treat as context
                  out << " #{l.chomp}\n"
                end
                i += 1
              end
            elsif line =~ /^[ +\-]/
              # missing @@ header for this hunk; synthesize as full-file replacement
              old_lines = read_file_lines.call(rel)
              new_lines = []
              # Build new version heuristically: remove '-' lines, keep '+' and ' ' without prefixes
              j = i
              while j < body.length && body[j] !~ /^@@/ && body[j] !~ /^--- / && body[j] !~ /^\+\+\+ /
                l = body[j]
                if l.start_with?('+')
                  new_lines << l[1..-1].to_s.chomp
                elsif l.start_with?(' ')
                  new_lines << l[1..-1].to_s.chomp
                end
                j += 1
              end
              out << "@@ -1,#{old_lines.length} +1,#{new_lines.length} @@\n"
              # Replace entire file content
              old_lines.each { |ol| out << "-#{ol}\n" }
              new_lines.each { |nl| out << "+#{nl}\n" }
              i = j
            else
              # skip stray lines (headers will be set by us)
              i += 1
            end
          end
        else
          # Treat body as the full new file content
          new_lines = body.map { |l| l.chomp }
          old_lines = read_file_lines.call(rel)
          out << "--- #{a_name}\n"
          out << "+++ #{b_name}\n"
          out << "@@ -#{old_lines.empty? ? '0,0' : "1,#{old_lines.length}"} +#{new_lines.empty? ? '0,0' : "1,#{new_lines.length}"} @@\n"
          old_lines.each { |l| out << "-#{l}\n" }
          new_lines.each { |l| out << "+#{l}\n" }
        end
      end
    end

    text = out.join
    return text.end_with?("\n") ? text : text + "\n"
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

    # 1) Convert to canonical unified diff
    generated = convert_chatgpt_patch(patch_text)

    # 2) Write to a temp file for clearer diagnostics
    tmp_patch = file('patch.diff')
    tmp_patch.write generated

    tried = []
    used_strip = nil
    final = { stdout: '', stderr: '', exit_status: 1 }

    Dir.chdir(ComputerUse.root) do
      # Auto-detect strip when not specified or when passed as 0
      candidate_strips = strip.nil? || strip.to_i == 0 ? (0..4).to_a : [strip.to_i]

      candidate_strips.each do |p|
        args = ["-p#{p}", '--dry-run', '-i', tmp_patch]
        res = cmd_json(:patch, args)
        tried << { strip: p, stdout: res[:stdout], stderr: res[:stderr], exit_status: res[:exit_status] }
        if res[:exit_status].to_i == 0
          used_strip = p
          final = res
          break
        end
      end

      # If --dry-run failed for all, consider apply_direct and return structured diagnostics
      if used_strip.nil?
        suggestion = 'Could not auto-detect -p. Review tried_strips, verify paths in generated_patch, or specify strip explicitly.'

        # Attempt apply_direct only if requested
        applied_directly = false
        if apply_direct
          # Try a limited direct apply for ChatGPT-style Add/Update/Delete where body looked like full content
          begin
            # Re-parse original text for blocks and directly write content for add/update, delete files for delete
            applied_directly = false
            root = ComputerUse.root

            # very similar parsing as in convert_chatgpt_patch
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

            # Determine if blocks are plain content (not unified diff)
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
                  # Write body as-is (full new content)
                  content = blk[:body].join
                  # backup if exists
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
                    # consider as success (already deleted)
                    applied_directly = true
                  end
                end
              end
            end
          rescue => e
            # include error in diagnostics
            tried << { strip: 'apply_direct', stdout: '', stderr: e.message, exit_status: 1 }
            applied_directly = false
          end
        end

        next {
          stdout: final[:stdout],
          stderr: final[:stderr],
          exit_status: final[:exit_status],
          generated_patch: generated,
          tried_strips: tried,
          used_strip: used_strip,
          applied: false,
          applied_directly: applied_directly,
          suggestion: suggestion
        }.to_json
      end

      # At this point we have a chosen strip that passes --dry-run
      if dry_run
        next {
          stdout: final[:stdout],
          stderr: final[:stderr],
          exit_status: final[:exit_status],
          generated_patch: generated,
          tried_strips: tried,
          used_strip: used_strip,
          applied: false,
          applied_directly: false,
          suggestion: 'Dry run OK. Re-run with dry_run: false to apply.'
        }.to_json
      end

      # Apply for real
      apply_res = cmd_json(:patch, ["-p#{used_strip}", '-i', tmp_patch])
      next {
        stdout: apply_res[:stdout],
        stderr: apply_res[:stderr],
        exit_status: apply_res[:exit_status],
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
