# This script is a sample of what someone might write on the web.
# I need to be able to do a lot, but NOTHING malicious to the server.

# This file is loaded at safe-level 2.

puts "Loaded testA.rb"
require 'testA-lib'

class RubyHook
  def respond_to(request)
    # Code is run at runtime with save-level 2.
    return "#{TestALib.hello} (#{request.resource_uri}) :)"
  end
end
