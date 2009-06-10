require "socket"
require 'openssl'

# This TcpHub class accepts connections, instantiates them into an appropriate object depending on the connected port,
# and passes data as it comes in to that object. You can specify several ip:ports to listen to, and a class that will initialize
# with new connections on the listening port. You can also specify ip:ports to initiate a connection to, and a class to initialize
# the connection with. These classes should respond to instance method #receive_data, which will be called whenever there is new data to
# read on the socket; and the instance should manage its own understanding of the data it receives.
# 
# Example:
#   TcpHub.new(
#     :listen => { '0.0.0.0:194' => IRCBot,
#                  '0.0.0.0:80' => WebServer},
#     :connect => {'0.0.0.0:80' => WebClient}
#   ).run
# This example listens on two ports, 194 and 80, and instantiates incoming connections using the classes IRCBot and WebServer, respectively.
# When data then comes in on those connected sockets, the methods defined in those classes handle the incoming data.
# Think as if "A connection coming in on port 194 is an IRCBot connection, and so the incoming socket will be wrapped by an IRCBot instance,
# and its incoming data will be handled by the IRCBot's #receive_data instance method." Secondly, the server is listening to port 80 as a WebServer,
# then immediately following, it also connects as a client to port 80 and handles that connection as a WebClient. As you can see, you may pass
# more arguments in by turning the value into an array - the first element must be the initializing class, and the rest static arguments to pass
# into the initializing method.
# 
# The way this server differs from most ruby web services is that all the services still live initially in the same process. No threading is done
# except when you decide to thread out a process to handle a request. You may safely do so - when the socket is closed, the TcpHub will
# reap it.
class TcpHub
  DEFAULT_SSL_OPTIONS = Hash.new do |h,k|
    case k
    when :SSLCertificate
      h[k] = OpenSSL::X509::Certificate.new(File.read(h[:SSLCertificateFile]))
    when :SSLPrivateKey
      h[k] = OpenSSL::PKey::RSA.new(File.read(h[:SSLPrivateKeyFile]))
    else
      nil
    end
  end
  # Must specify these if you use auto generated certificate.
  # :SSLCertName          => [['CN', 'my-ip']],
  # :SSLCertComment       => "Generated by Ruby/OpenSSL"
  DEFAULT_SSL_OPTIONS.merge!(
    :GenerateSSLCert      => false,
    :ServerSoftware       => "Ruby TCP Router OpenSSL/#{::OpenSSL::OPENSSL_VERSION.split[1]}",
    :SSLCertificateFile   => 'cert.pem',
    :SSLPrivateKeyFile    => 'key.pem',
    :SSLClientCA          => nil,
    :SSLExtraChainCert    => nil,
    :SSLCACertificateFile => 'cacert.pem',
    :SSLCACertificatePath => nil,
    :SSLCertificateStore  => nil,
    :SSLVerifyClient      => ::OpenSSL::SSL::VERIFY_PEER,
    :SSLVerifyDepth       => 1,
    :SSLVerifyCallback    => nil,   # custom verification
    :SSLTimeout           => nil,
    :SSLOptions           => nil,
    :SSLStartImmediately  => true
  )

  class << self
    def ssl_config(config=DEFAULT_SSL_OPTIONS)
      @ssl_config ||= config
    end
  end

  def running?
    @status == :running
  end
  def stop!
    @status = :stop
  end

  attr_reader :router
  def initialize(routes={})
    @router = {}
    # Set up the listening sockets
    (routes[:listen] || {}).each do |ip_port,instantiate_klass|
      ip, port = ip_port.split(/:/)
      socket = TCPServer.new(ip, port)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
      @router[socket] = instantiate_klass
      puts "Listening on #{ip_port} for #{instantiate_klass.name} messages..."
    end
    # Set up the listening SSL sockets
    (routes[:ssl_listen] || {}).each do |ip_port,instantiate_klass|
      ip, port = ip_port.split(/:/)
      socket = TCPServer.new(ip, port)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)

      ssl_socket = ::OpenSSL::SSL::SSLServer.new(socket, ssl_context)
      ssl_socket.start_immediately = self.class.ssl_config[:SSLStartImmediately]

      @router[ssl_socket] = instantiate_klass
      puts "Listening on #{ip_port} (SSL) for #{instantiate_klass.name} messages..."
    end
    # Set up the connect sockets
    (routes[:connect] || {}).each do |ip_port,args|
      args = [args] unless args.is_a?(Array); instantiate_klass = args.shift
      ip, port = ip_port.split(/:/)
      socket = TCPSocket.new(ip, port)
      clients[socket] = instantiate_klass.new(self,socket,*args)
      puts "Connecting to #{ip_port} for #{instantiate_klass.name} messages..."
    end
  end

  def run
    @status = :running
    trap("INT") {stop!} # This will end the event loop within 0.5 seconds when you hit Ctrl+C
    loop do
      begin
        # Clean up any closed clients
        clients.each_key do |sock|
          if sock.closed?
            clients[sock].upon_unbind if clients[sock].respond_to?(:upon_unbind)
            clients.delete(sock)
          end
        end
      
        event = select(listen_sockets + client_sockets,nil,nil,0.5)
        if event.nil? # nil would be a timeout, we'd do nothing and start loop over. Of course here we really have no timeout...
          if !running?
            if client_sockets.empty?
              # It's the next time around after we closed all the client connections.
              break
            else
              puts "Closing all client connections."
              close_all_clients!
              puts "Closing all listening ports."
              shutdown_listeners!
            end
          end
        else
          event[0].each do |sock| # Iterate through all sockets that have pending activity
            if listen_sockets.include?(sock) # Received a new connection to a listening socket
              new_sock = accept_client(sock)
              clients[new_sock].upon_new_connection if clients[new_sock].respond_to?(:upon_new_connection)
            else # Activity on a client-connected socket
              if sock.eof? # Socket's been closed by the client
                puts "Connection #{clients[sock].inspect} was closed by the client."
                sock.close
                clients[sock].upon_unbind if clients[sock].respond_to?(:upon_unbind)
                client = clients[sock]
                clients.delete(sock)
              else # Data in from the client
                begin
                  if sock.respond_to?(:read_nonblock)
                    10.times {
                      data = sock.read_nonblock(4096)
                      clients[sock].receive_data(data)
                      break if sock.closed?
                    }
                  else
                    data = sock.sysread(4096)
                    clients[sock].receive_data(data)
                  end
                rescue Errno::EAGAIN, Errno::EWOULDBLOCK => e
                  # no-op. This will likely happen after every request, but that's expected. It ensures that we're done with the request's data.
                rescue Errno::ECONNRESET, Errno::ECONNREFUSED, EOFError => e
                  puts "Closed Err: #{e.inspect}"; $stdout.flush
                  clients[sock].upon_unbind if clients[sock].respond_to?(:upon_unbind)
                end
              end
            end
          end
        end
      rescue IOError # this is tripped when we thread away and close the socket sometime within the thread.
      end
    end
  end

  def clients
    @clients ||= {}
  end

  def close_all_clients!
    puts "Closing #{client_sockets.length} client connections..."
    client_sockets.each { |socket| socket.close }
  end
  def shutdown_listeners!
    puts "Shutting down #{listen_sockets.length} listeners..."
    listen_sockets.each { |socket| socket.close }
  end

  private
    def listen_sockets
      @router.keys
    end

    def accept_client(source_socket)
      client_socket = source_socket.accept
      connection = @router[source_socket].new(self,client_socket)
      clients[client_socket] = connection
    end

    def client_sockets
      @clients.keys
    end

    def ssl_context
      unless @ssl_context
        @ssl_context = OpenSSL::SSL::SSLContext.new
        @ssl_context.client_ca         = self.class.ssl_config[:SSLClientCA]
        @ssl_context.ca_file           = self.class.ssl_config[:SSLCACertificateFile]
        @ssl_context.ca_path           = self.class.ssl_config[:SSLCACertificatePath]
        @ssl_context.extra_chain_cert  = self.class.ssl_config[:SSLExtraChainCert]
        @ssl_context.cert_store        = self.class.ssl_config[:SSLCertificateStore]
        @ssl_context.verify_mode       = self.class.ssl_config[:SSLVerifyClient]
        @ssl_context.verify_depth      = self.class.ssl_config[:SSLVerifyDepth]
        @ssl_context.verify_callback   = self.class.ssl_config[:SSLVerifyCallback]
        @ssl_context.timeout           = self.class.ssl_config[:SSLTimeout]
        @ssl_context.options           = self.class.ssl_config[:SSLOptions]
        if self.class.ssl_config[:GenerateSSLCert]
          @ssl_context.key = OpenSSL::PKey::RSA.generate(4096)
          ca = OpenSSL::X509::Name.parse("/C=US/ST=Michigan/O=BehindLogic/CN=behindlogic.com/emailAddress=cert@desktopconnect.com")
          cert = OpenSSL::X509::Certificate.new
          cert.version = 2
          cert.serial = 1
          cert.subject = ca
          cert.issuer = ca
          cert.public_key = @ssl_context.key.public_key
          cert.not_before = Time.now
          cert.not_after = Time.now + 3600 # this http session should last no longer than 1 hour
          @ssl_context.cert = cert
        else
          @ssl_context.cert              = self.class.ssl_config[:SSLCertificate]
          @ssl_context.key               = self.class.ssl_config[:SSLPrivateKey]
        end
      end
      @ssl_context
    end
end