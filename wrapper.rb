request = Thread.current[:request]
socket = Thread.current[:socket]

script_name = request.resource_uri.gsub(/.*\//,'').untaint
  puts "Running script: #{script_name}"
$: << "test_scripts/#{script_name}"

# Require any gems needed by the script that need extra access to load; runtime will be in safe level 2.
require 'httparty'

# Now we are SAFE'd, and we can load the script.
$SAFE = 2
load("test_scripts/#{script_name}.rb")

# Get the response
response = RubyHook.new.respond_to(request)

# And send it!
socket.write "Content-Type: image/png\nContent-Length: #{response.length}\n\n#{response}"
socket.close
  puts "Done."
