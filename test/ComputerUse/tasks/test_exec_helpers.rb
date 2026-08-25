ROOT = File.expand_path('../../..', __dir__)
$LOAD_PATH.unshift(ROOT)

require 'scout'
require 'scout-ai'
require 'test/unit'

# Re-open the workflow module without triggering workflow autoinstall, then
# load the task file under test directly.
module ComputerUse
  extend Workflow
end

require File.join(ROOT, 'lib/ComputerUse/exceptions')
require File.join(ROOT, 'lib/ComputerUse/tasks/exec')

class TestExecCondensing < Test::Unit::TestCase
  def step_object
    o = Object.new
    o.extend ComputerUse.step_module
    o
  end

  def test_error_line_match
    o = step_object
    assert o.error_line_match?("sed: can't read /etc/shadow: No such file or directory")
    assert o.error_line_match?('Traceback (most recent call last):')
    assert o.error_line_match?("NameError: undefined local variable or method `foo' for main")
    assert o.error_line_match?('E   AssertionError: expected 1 got 2')
    assert o.error_line_match?('fatal: not a git repository')
    assert o.error_line_match?('gcc: error: no such file or directory')
    assert !o.error_line_match?('noise line 42')
    assert !o.error_line_match?('Building module foo')
  end

  def test_condense_returns_small_output_untouched
    o = step_object
    small = "sed: can't read /etc/shadow: No such file or directory\n"
    res = o.condense_stderr(small, max_chars: 4000)
    assert_equal small, res
  end

  def test_condense_huge_stderr_with_buried_error
    o = step_object
    noise = (1..5000).map { |i| "noise line #{i}" }.join("\n")
    raw = noise + "\nFATAL: the real error - cannot open /etc/shadow (Permission denied)\n"
    res = o.condense_stderr(raw, max_chars: 4000)
    assert res.length < 4000
    assert_match %r{cannot open /etc/shadow}, res
    assert_match(/omitted/, res)
    assert_match(/noise line 5000/, res)
    assert !res.include?("noise line 1\n")
  end

  def test_condense_collapses_repeated_lines
    o = step_object
    raw = (1..200).map { 'identical warning line' }.join("\n") + "\nError: something failed\n"
    res = o.condense_stderr(raw, max_chars: 4000)
    assert_match(/identical warning line/, res)
    assert_match(/x 200/, res)
    assert_match(/Error: something failed/, res)
  end

  def test_condense_keeps_python_style_tail_error
    o = step_object
    tb = <<~TB
      /path/to/script.py:10 in main
      Traceback (most recent call last):
        File "/path/to/script.py", line 10, in main
          do_work()
        File "/path/to/script.py", line 4, in do_work
          raise ValueError("bad value")
      ValueError: bad value
    TB
    res = o.condense_stderr(tb, max_chars: 4000)
    assert res.include?('ValueError: bad value')
  end

  def test_condense_strips_process_failed_argv_dump
    o = step_object
    raw = 'Process 123 failed - /usr/bin/bwrap ' + (1..40).map { |i| "--ro-bind /some/long/path/#{i} /some/long/path/#{i}" }.join(' ') + ' -- /usr/bin/sed -i s/a/b/ /etc/shadow failed with error status 1.' + "\n" +
          "sed: can't read /etc/shadow: No such file or directory\n"
    res = o.condense_stderr(raw, max_chars: 4000)
    assert !res.include?('--ro-bind /some/long/path/1')
    assert_match(/No such file/, res)
    assert res.length < raw.length
  end

  def test_condense_strips_host_ruby_backtrace
    o = step_object
    frames = [
      'Process 17 failed - bwrap ... failed with error status 1.',
      "/gems/scout-essentials-1.9.0/lib/scout/cmd.rb:584:in `cmd'",
      "/gems/scout-gear-10.12.2/lib/scout/workflow/step.rb:154:in `exec'",
      "/lib/rbbt/workflow/refactor.rb:9:in `exec'",
      "/lib/scout/persist.rb:63:in `persist'",
      'the real error: command not found: foobar',
    ].join("\n") + "\n"
    res = o.condense_stderr(frames, max_chars: 4000)
    assert !res.include?('persist.rb')
    assert res.include?('the real error: command not found: foobar')
  end

  def test_condense_respects_zero_limit_off
    o = step_object
    raw = (1..1000).map { |i| "x #{i}" }.join("\n")
    res = o.condense_stderr(raw, max_chars: 0)
    assert_equal raw, res
  end

  def test_failure_result_persists_full_stream
    o = step_object
    require 'tmpdir'
    Dir.mktmpdir do |dir|
      # stub files_dir
      o.define_singleton_method(:files_dir) { dir }
      noise = (1..5000).map { |i| "n #{i}" }.join("\n")
      raw = noise + "\nFATAL: the real error\n"
      res = o.failure_result(1, 'out', raw, prefix: nil)
      assert res[:stderr].length <= 4000
      assert_match(/FATAL/, res[:stderr])
      assert res[:stderr_full]
      assert File.read(res[:stderr_full]).include?('n 1')
    end
  end

  def test_summarize_process_failed
    o = step_object
    msg = 'Process 154052 failed - /usr/bin/bwrap ' + (1..60).map { |i| "--ro-bind /host/some/very/long/path/number/#{i} /sandbox/some/very/long/path/number/#{i}" }.join(' ') + ' -- /usr/bin/patch --batch -p1 -i /tmp/patch.diff failed with error status 2.'
    res = o.summarize_process_failed(msg)
    assert res.length < msg.length / 2
    assert_match(/patch --batch -p1 -i \/tmp\/patch\.diff/, res)
    assert_match(/full argv elided/, res)
    assert !res.include?('--setenv PATH /a:/b:/c')
  end
end
