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

require_relative 'lib/ComputerUse/tasks/documents'
require_relative 'lib/ComputerUse/tasks/filesystem'
require_relative 'lib/ComputerUse/tasks/ruby'
require_relative 'lib/ComputerUse/tasks/exec'
#require_relative 'lib/ComputerUse/tasks/web'

