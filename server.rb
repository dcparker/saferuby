#!/usr/bin/ruby

require 'lib/tcphub'
require 'lib/http11_parser'
require 'rubygems'

Thread.abort_on_exception = true

class ScriptRunner
  # Http11Parser handles the receive_data callback of TcpHub
  # and gives us more useful callbacks that pertain specifically to HTTP.
  include EventParsers::Http11Parser

  def initialize(server, socket)
    @socket = socket
  end

  # Callbacks for TcpHub:
  #   upon_new_connection
  #   receive_data(data)
  #   upon_unbind

  # Callbacks for Http11Parser:
  #   upon_new_request(request)       # after first HTTP line
  #   receive_header(request, header) # after each header is received
  #   upon_headers_finished(request)  # after all headers are received
  #   process_request(request)        # after the full request is received

  def process_request(request)
    # Thread it
    #   - so that we can continue right on to the next request, and
    #   - so that SAFE will be sandboxed.
    Thread.new do
      begin
        # Save these variables for the sandboxed environment
        Thread.current[:request] = request
        Thread.current[:socket] = @socket

        # Run the wrapper inside an anonymous module. The environment
        # loaded so far is available to this new environment, but now
        # it can't modify this main memory space.
        load("wrapper.rb", true)
      rescue SecurityError, IOError, LoadError, SyntaxError => e
        @socket.write "Security Error: #{e.to_s}\n#{e.backtrace.join("\n")}"
        puts "[#{Time.now.inspect}] Done (Error)"
        begin
          @socket.close
        rescue IOError
        end
      rescue => e
        puts "[#{Time.now.inspect}] Done (Error)"
      end
    end
  end
end

$server = TcpHub.new( :listen => {"0.0.0.0:8000" => ScriptRunner} )
$server.run
