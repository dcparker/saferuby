request = Thread.current[:request]
socket = Thread.current[:socket]

script_name = request.resource_uri.gsub(/.*\//,'').untaint
  puts "Running script: #{script_name}"
$: << "test_scripts/#{script_name}"
load("test_scripts/#{script_name}.rb")

response = RubyHook.new.respond_to(request)

socket.write "Content-Type: image/png\nContent-Length: #{response.length}\n\n#{response}"
socket.close
  puts "Done."
