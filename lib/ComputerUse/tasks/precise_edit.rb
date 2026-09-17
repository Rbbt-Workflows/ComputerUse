require 'digest'
require 'tempfile'

module ComputerUse
  desc <<-EOF
Apply one exact, count-checked mutation to a file under the allowed write paths.
The operation is replace, insert (after the selector), or delete. The file is
changed only when the selector count and optional SHA-256 precondition match.
  EOF
  input :path, :path, 'File to mutate', nil, required: true
  input :operation, :select, 'Mutation operation', nil, required: true, select_options: %w(replace insert delete)
  input :selector, :text, 'Exact text to find', nil, required: true
  input :replacement, :text, 'Replacement or inserted content', nil, required: true
  input :expect_matches, :integer, 'Required exact number of selector matches', nil, required: true
  input :expected_hash, :string, 'Optional SHA-256 hash of the original file'
  extension :json
  task :precise_edit => :json do |path, operation, selector, replacement, expect_matches, expected_hash|
    file = normalize(path, :write)
    operation = operation.to_s
    selector = selector.to_s
    replacement = replacement.to_s
    expected = expect_matches.to_i
    raise ParameterException, 'selector must not be empty' if selector.empty?
    raise ParameterException, 'expect_matches must be non-negative' if expected < 0
    raise ParameterException, "File not found: #{file}" unless Open.exists?(file)
    raise ParameterException, "File is a directory: #{file}" if Open.directory?(file)

    original = File.binread(file)
    actual_hash = Digest::SHA256.hexdigest(original)
    result = {
      status: 'precondition_failed', resolved_path: file, existence: true,
      matches: 0, precondition: {expected_matches: expected, expected_hash: expected_hash,
                                  actual_hash: actual_hash}, verification: {}
    }
    if expected_hash && expected_hash != actual_hash
      result[:verification] = {changed: false, reason: 'hash_mismatch'}
      next result
    end

    matches = original.scan(Regexp.escape(selector)).length
    result[:matches] = matches
    unless matches == expected
      result[:verification] = {changed: false, reason: 'match_count_mismatch'}
      next result
    end

    updated = case operation
              when 'replace' then original.gsub(selector) { replacement }
              when 'delete' then original.gsub(selector, '')
              when 'insert' then original.gsub(selector) { |match| match + replacement }
              else raise ParameterException, "Unknown operation: #{operation}"
              end

    Tempfile.create(['precise-edit-', '.tmp'], File.dirname(file), binmode: true) do |tmp|
      tmp.write(updated)
      tmp.flush
      tmp.fsync rescue nil
      File.chmod(File.stat(file).mode & 07777, tmp.path) rescue nil
      File.rename(tmp.path, file)
    end
    result[:status] = 'updated'
    result[:verification] = {changed: true, hash: Digest::SHA256.hexdigest(updated),
                             bytes_before: original.bytesize, bytes_after: updated.bytesize}
    result
  end

  export_exec :precise_edit
end
