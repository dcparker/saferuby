# This script is a sample of what someone might write on the web.
# I need to be able to do a lot, but NOTHING malicious to the server.

# This file is loaded and run at safe-level 2.

require 'httparty'
require 'testA-lib'

class RubyHook
  def respond_to(request)
    return Representative.get('http://whoismyrepresentative.com/whoismyrep.php?zip=49250').inspect 
  end
end
