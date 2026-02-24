require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require 'scout'
Workflow.require_workflow 'ComputerUse'
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestClass < Test::Unit::TestCase
  def test_convert
    patch=<<-EOF
*** Begin Patch
*** Update File: [FILE]
@@
-require 'scout/gear'
-require 'scout-ai'
-require_relative '../lib/swing_trader/agent'
-require_relative '../lib/swing_trader/swing_trader'
+require 'scout/gear'
+require_relative '../lib/swing_trader/swing_trader'
*** End Patch
    EOF

    file =<<-EOF
require 'scout/gear'
require 'scout-ai'
require_relative '../lib/swing_trader/agent'
require_relative '../lib/swing_trader/swing_trader'
    EOF

    target =<<-EOF
--- a/[FILE]
+++ b/[FILE]
@@ -1,4 +1,2 @@
-require 'scout/gear'
-require 'scout-ai'
-require_relative '../lib/swing_trader/agent'
-require_relative '../lib/swing_trader/swing_trader'
+require 'scout/gear'
+require_relative '../lib/swing_trader/swing_trader'
    EOF

    TmpFile.with_file(file) do |tmpfile|
      Misc.in_dir File.dirname tmpfile do
        patch = patch.gsub('[FILE]', File.basename(tmpfile))
        target = target.gsub('[FILE]', File.basename(tmpfile))
        conveted = ComputerUse.convert_chatgpt_patch(patch)
        assert_equal target, conveted
      end
    end
  end
end

