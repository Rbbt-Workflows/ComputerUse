require 'scout'
require 'scout-ai'

module ComputerUse
  MEMORY = Scout.Memory.find(:lib)

  extend Workflow

  task current_time: :string do
    Time.now.to_s
  end

  export_exec :current_time
end

require_relative 'lib/ComputerUse/exceptions'
require_relative 'lib/ComputerUse/tasks/filesystem'
require_relative 'lib/ComputerUse/tasks/exec'
require_relative 'lib/ComputerUse/tasks/patch'
require_relative 'lib/ComputerUse/tasks/documents'
require_relative 'lib/ComputerUse/tasks/playwright'
require_relative 'lib/ComputerUse/tasks/web'
require_relative 'lib/ComputerUse/tasks/tsv'

# Register an association TSV in a local or workflow KnowledgeBase. Keep the
# task in workflow.rb so Scout's development reload refreshes its definition.
require 'scout/knowledge_base'

ComputerUse.module_eval do

desc 'Register an association TSV file in a KnowledgeBase.'
input :name, :string, 'Association database name', nil, required: true
input :source_file, :path, 'Association TSV file', nil, required: true
input :source, :string, 'Association source field specification', nil, required: true
input :target, :string, 'Association target field specification', nil, required: true
input :knowledge_base, :string, 'current, :default, a workflow name, or an allowed KnowledgeBase directory', 'current'
input :fields, :array, 'Association information fields to retain', nil
input :undirected, :boolean, 'Treat association as undirected; omit to let Scout infer', nil
input :identifiers, :path, 'Identifier mapping TSV', nil
input :namespace, :string, 'KnowledgeBase/association namespace', nil
input :description, :text, 'Human-readable database description', nil
task kb_register: :json do |name, source_file, source, target, knowledge_base, fields, undirected, identifiers, namespace, description|
  database_name = name.to_s
  unless database_name.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/) && !%w[. ..].include?(database_name)
    raise ParameterException, 'database name must be a simple name (letters, digits, dot, underscore, hyphen); path separators are not allowed'
  end
  raise ParameterException, 'source field specification cannot be empty' if source.to_s.empty?
  raise ParameterException, 'target field specification cannot be empty' if target.to_s.empty?

  data_path = normalize(source_file, :read)
  raise ParameterException, "Association TSV file not found: #{data_path}" unless File.file?(data_path) && File.readable?(data_path)

  kb_selector = knowledge_base.to_s
  case kb_selector
  when 'current', '.', ':default', 'default'
    # Scout's default KnowledgeBase resolves under the current project's
    # var/knowledge_base/default directory.
    kb = KnowledgeBase.load(:default)
    kb_path = normalize(kb.dir.to_s, :write)
    kb_path = File.expand_path(kb_path)
    FileUtils.mkdir_p(kb_path) unless File.directory?(kb_path)
    kb.load
  else
    if kb_selector.start_with?('/', './', '../', '~/')
      kb_path = normalize(kb_selector, :write)
      kb_path = File.expand_path(kb_path)
      FileUtils.mkdir_p(kb_path) unless File.directory?(kb_path)
      kb = KnowledgeBase.load(kb_path)
    else
      workflow = begin
        Workflow.require_workflow(kb_selector)
      rescue StandardError => e
        raise ParameterException, "Could not load workflow KnowledgeBase '#{kb_selector}': #{e.message}"
      end
      kb = workflow.knowledge_base
      if kb.nil?
        raise ParameterException, "Workflow '#{kb_selector}' has no library directory for its KnowledgeBase" if workflow.libdir.nil?
        kb_path = File.expand_path(File.join(workflow.libdir.to_s, 'var', 'knowledge_base'))
        kb_path = normalize(kb_path, :write)
        kb_path = File.expand_path(kb_path)
        FileUtils.mkdir_p(kb_path)
        kb = KnowledgeBase.load(kb_path)
        workflow.knowledge_base = kb
      else
        kb_path = normalize(kb.dir.to_s, :write)
        kb_path = File.expand_path(kb_path)
        FileUtils.mkdir_p(kb_path) unless File.directory?(kb_path)
        kb.load
      end
    end
  end

  raise ParameterException, "KnowledgeBase directory is not writable: #{kb_path}" unless File.directory?(kb_path) && File.writable?(kb_path)

  registration_options = {source: source.to_s, target: target.to_s}
  registration_options[:fields] = Array(fields).map(&:to_s) unless fields.nil? || fields.empty?
  registration_options[:undirected] = undirected unless undirected.nil?
  registration_options[:identifiers] = normalize(identifiers, :read) unless identifiers.nil? || identifiers.to_s.empty?
  registration_options[:namespace] = namespace.to_s unless namespace.nil? || namespace.to_s.empty?
  registration_options[:description] = description.to_s unless description.nil? || description.to_s.empty?

  kb.register(database_name, File.expand_path(data_path), registration_options)
  kb.save
  {status: 'registered', knowledge_base: kb_path, name: database_name,
   file: File.expand_path(data_path), options: registration_options,
   databases: kb.all_databases.map(&:to_s)}
end
export :kb_register
end
