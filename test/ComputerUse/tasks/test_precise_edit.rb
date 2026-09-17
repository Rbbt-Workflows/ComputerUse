require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path('../../../workflow', __dir__)

class TestPreciseEdit < Test::Unit::TestCase
  def run_edit(path, operation, selector, replacement, count, hash=nil)
    ComputerUse.job(:precise_edit, nil, path: path, operation: operation,
      selector: selector, replacement: replacement, expect_matches: count,
      expected_hash: hash).run
  end

  def test_replace_and_insert
    TmpFile.with_file("a\nb\na\n") do |path|
      assert_equal 'updated', run_edit(path, 'replace', 'b', 'B', 1)[:status]
      assert_equal "a\nB\na\n", File.read(path)
      assert_equal 'updated', run_edit(path, 'insert', 'B', '!', 1)[:status]
      assert_equal "a\nB!\na\n", File.read(path)
    end
  end

  def test_replace_keeps_backslash_sequences_literal
    TmpFile.with_file("before\n") do |path|
      replacement = '\\& and \\1'
      assert_equal 'updated', run_edit(path, 'replace', 'before', replacement, 1)[:status]
      assert_equal "#{replacement}\n", File.read(path)
    end
  end

  def test_ambiguous_and_hash_mismatch_are_unchanged
    TmpFile.with_file("a\na\n") do |path|
      before = File.binread(path)
      assert_equal 'precondition_failed', run_edit(path, 'delete', 'a', '', 1)[:status]
      assert_equal before, File.binread(path)
      assert_equal 'precondition_failed', run_edit(path, 'delete', 'a', '', 2, 'bad')[:status]
      assert_equal before, File.binread(path)
    end
  end
end
