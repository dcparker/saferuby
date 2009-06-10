require 'base64'
module EventParsers

  # Implement this by including it in a class and call receive_data on every read event.
  # Callbacks available:
  #   upon_new_request(request)       # after first HTTP line
  #   receive_header(request, header) # after each header is received
  #   upon_headers_finished(request)  # after all headers are received
  #   process_request(request)        # after the full request is received
  module Http11Parser
    module BasicAuth
      ::UnparsableBasicAuth = Class.new(RuntimeError)

      class << self
        def parse(basic_auth_string)
          # Do the special decoding here
          if basic_auth_string =~ /^Basic (.*)$/
            auth_string = $1
            auth_plain = Base64.decode64(auth_string)
            return auth_plain.split(/:/,2)
          else
            warn "Bad Auth string!"
            raise UnparsableBasicAuth
          end
        end
      end

      def initialize(username, password)
        @username = username
        @password = password
      end

      def to_s
        # Do the special encoding here
      end
    end

    class HeaderAndEntityStateStore
      attr_accessor :state, :delimiter, :linebuffer, :textbuffer, :entity_size, :entity_pos, :bogus_lines

      def initialize(state, delimiter)
        @state = state
        @delimiter = delimiter
        reset!
      end

      def reset!
        @linebuffer = []
        @textbuffer = []
        @entity_size = nil
        @entity_pos = 0
        @bogus_lines = 0
      end

      def entity?
        !entity_size.nil? && entity_size > 0
      end

  	  def bogus_line!(ln=nil)
        puts "bogus line:\n#{ln}" if ln && $DEBUG
        @bogus_lines += 1
      end
    end
    
    class Request
      attr_accessor :method, :http_version, :resource_uri, :headers, :entity

      def initialize(request_params={})
        @http_version = request_params[:http_version] if request_params.has_key? :http_version
        @resource_uri = request_params[:resource_uri] if request_params.has_key? :resource_uri
        @headers      = request_params[:headers] if request_params.has_key? :headers
        @entity       = request_params[:entity] if request_params.has_key? :entity

        @headers ||= {}
        @entity ||= ''
      end

      def inspect
        "HTTP Request:\n\t#{@method} #{@resource_uri} HTTP/#{@http_version}\n\t#{@headers.map {|k,v| "#{k}: #{v}"}.join("\n\t")}\n\n\t#{@entity.to_s.gsub(/\n/,"\n\t")}"
      end

      def has_entity?
        @entity != ''
      end

      def basic_auth
        BasicAuth.parse(@headers['authorization']) if @headers['authorization']
      end
    end

    # HttpResponseRE = /\AHTTP\/(1.[01]) ([\d]{3})/i
    HttpRequestRE = /^(GET|POST|PUT|DELETE) (\/.*) HTTP\/([\d\.]+)[\r\n]?$/i
    BlankLineRE = /^[\n\r]+$/

		def receive_data(data)
			return unless (data and data.length > 0)

      @next_request ||= Request.new

      case parser.state
      when :init
  			if ix = data.index("\n")
  				parser.linebuffer << data[0...ix+1]
  				ln = parser.linebuffer.join
  				     parser.linebuffer.clear
          puts "[#{parser.state}]: #{ln}" if $DEBUG
          if ln =~ HttpRequestRE
            method, resource_uri, http_version = parse_init_line(ln)
            @next_request.method = method
            @next_request.resource_uri = resource_uri
            @next_request.http_version = http_version
            upon_new_request(@next_request) if respond_to?(:upon_new_request)
            # puts "Init: #{ln.inspect}"
            parser.state = :headers
          else
    			  parser.bogus_line!(ln)
          end
  				receive_data(data[(ix+1)..-1])
        else
          parser.linebuffer << data
        end
      when :headers
  			if ix = data.index("\n")
  				parser.linebuffer << data[0...ix+1]
  				ln = parser.linebuffer.join
  				     parser.linebuffer.clear
          puts "[#{parser.state}]: #{ln}" if $DEBUG
          # If it's a blank line, move to content state
          if ln =~ BlankLineRE
            upon_headers_finished(@next_request) if respond_to?(:upon_headers_finished)
            if parser.entity?
              # evaluate_headers(@next_request.headers)
              parser.state = :entity
            else
              receive_full_request
            end
          else
            header = parse_header_line(ln)
            # puts "Header: #{header.inspect}"
            receive_header(@next_request, header.to_a[0]) if respond_to?(:receive_header)
            @next_request.headers.merge!(header)
          end
  				receive_data(data[(ix+1)..-1])
  			else
  				parser.linebuffer << data
  			end
			when :entity
				if parser.entity_size
					chars_yet_needed = parser.entity_size - parser.entity_pos
					taking_this_many = [chars_yet_needed, data.length].sort.first
					parser.textbuffer << data[0...taking_this_many]
 					leftover_data = data[taking_this_many..-1]
					parser.entity_pos += taking_this_many
					if parser.entity_pos >= parser.entity_size
						entity_data = parser.textbuffer.join
						              parser.textbuffer.clear
						@next_request.entity << entity_data
            puts "[#{parser.state}]: #{entity_data}" if $DEBUG
            receive_full_request
					end
					receive_data(leftover_data)
				else
				  raise "TODO!"
          # receive_binary_data data
				end
        
		  else
        # Probably shouldn't ever be here?
        raise "Shouldn't be here!"
			end

      # TODO: Exception if number of parser.bogus_lines is higher than threshold
    end

    def process_request(request)
      puts "STUB - overwrite process_request in a subclass of Http11Parser to process this #{request.inspect}"
    end

    private
      def parse_init_line(ln)
        method, resource_uri, http_version = ln.match(HttpRequestRE).to_a[1..-1]
        # TODO: Exception if the request is improper!
        [method, resource_uri, http_version]
      end

      def parse_header_line(ln)
        ln.chomp!
        if ln =~ /:/
    			name,value = ln.split(/:\s*/,2)
          if name.downcase == 'content-length'
            parser.entity_size = Integer(value.gsub(/\D/,''))
            # TODO: Exception if content-length specified is too big
          end
    			{name.downcase => value}
  			else
  			  parser.bogus_line!(ln)
  			  {}
        end
      end

      def receive_full_request
        parser.state = :init
        process_request(@next_request)
        puts "Received request. Prepared for next request." if $DEBUG
        parser.reset!
        @next_request = nil
      end

      def parser
        @parser ||= HeaderAndEntityStateStore.new(:init, "\n")
      end
  end
end
