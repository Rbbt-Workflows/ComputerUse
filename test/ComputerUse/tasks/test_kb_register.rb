require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path('../../../workflow', __dir__)
require 'tmpdir'
require 'scout/knowledge_base'

class TestComputerUseKnowledgeBaseRegister < Test::Unit::TestCase
  def with_paths
    Dir.mktmpdir('computeruse-kb-register') do |root|
      source_dir = File.join(root, 'source')
      target_dir = File.join(root, 'kb')
      FileUtils.mkdir_p(source_dir)
      FileUtils.mkdir_p(target_dir)
      source = File.join(source_dir, 'association.tsv')
      File.write(source, "#: :type=:double\n#ID\tTarget\tEvidence\nA\tB\tPMID:1\n")
      yield root, source_dir, target_dir, source
    end
  end

  def run_task(**inputs)
    ComputerUse.job(:kb_register, nil, inputs).run
  end

  def test_registers_association_database_in_explicit_knowledge_base_directory
    with_paths do |_root, source_dir, target_dir, source|
      result = run_task(name: 'example', source_file: source, source: 'ID', target: 'Target',
                        knowledge_base: target_dir, fields: ['Evidence'], description: 'test association')
      assert_equal 'registered', result[:status]
      assert_equal 'example', result[:name]
      assert_equal File.expand_path(source), result[:file]
      kb = KnowledgeBase.load(target_dir)
      assert_include kb.all_databases.map(&:to_s), 'example'
      assert_equal File.expand_path(source), kb.database_file('example')
      options = kb.registered_options('example')
      assert_equal 'ID', options[:source]
      assert_equal 'Target', options[:target]
      assert_equal ['Evidence'], options[:fields]
      assert_equal 'test association', options[:description]
      assert File.file?(File.join(target_dir, 'config', 'registry')) || Dir.exist?(File.join(target_dir, 'config'))
    end
  end

  def test_rejects_write_target_outside_sandbox_permissions
    with_paths do |root, _source_dir, _target_dir, source|
      outside = '/etc/computeruse-kb-register-not-allowed'
      error = assert_raise(SandboxAccessViolation) do
        run_task(name: 'blocked', source_file: source, source: 'ID', target: 'Target', knowledge_base: outside)
      end
      assert_match(/not write allowed/, error.message)
    end
  end

  def test_rejects_unsafe_database_name
    with_paths do |_root, _source_dir, target_dir, source|
      assert_raise(ParameterException) do
        run_task(name: '../bad', source_file: source, source: 'ID', target: 'Target', knowledge_base: target_dir)
      end
    end
  end

  def test_rejects_missing_source_target_and_unknown_workflow
    with_paths do |_root, _source_dir, target_dir, source|
      assert_raise(ParameterException) do
        run_task(name: 'missing-source', source_file: source, source: '', target: 'Target', knowledge_base: target_dir)
      end
      assert_raise(ParameterException) do
        run_task(name: 'missing-target', source_file: source, source: 'ID', target: '', knowledge_base: target_dir)
      end
      assert_raise(ParameterException) do
        run_task(name: 'bad-workflow', source_file: source, source: 'ID', target: 'Target', knowledge_base: 'WorkflowThatDoesNotExist')
      end
    end
  end
end
