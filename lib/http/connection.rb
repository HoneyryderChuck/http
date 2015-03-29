require "http/response/parser"

module HTTP
  # A connection to the HTTP server
  class Connection
    attr_reader :socket, :parser, :persistent, :keep_alive_timeout,
                :pending_request, :pending_response

    # Attempt to read this much data
    BUFFER_SIZE = 16_384

    def initialize(req, options)
      @persistent = options.persistent?

      @keep_alive_timeout = options[:keep_alive_timeout]

      @parser = Response::Parser.new

      @socket = options[:timeout_class].new(options[:timeout_options])
      @socket.connect(options[:socket_class], req.socket_host, req.socket_port)

      @socket.start_tls(
        req.uri.host,
        options[:ssl_socket_class],
        options[:ssl_context]
      ) if req.uri.is_a?(URI::HTTPS) && !req.using_proxy?

      reset_timer
    end

    # Send a request to the server
    #
    # @param [Request] Request to send to the server
    # @return [Nil]
    def send_request(req)
      if pending_response
        fail StateError, "Tried to send a request while one is pending already. Make sure you read off the body."
      elsif pending_request
        fail StateError, "Tried to send a request while a response is pending. Make sure you've fully read the body from the request."
      end

      @pending_request = true

      req.stream socket

      @pending_response = true
      @pending_request = nil
    end

    # Read a chunk of the body
    #
    # @return [String] data chunk
    # @return [Nil] when no more data left
    def readpartial(size = BUFFER_SIZE)
      return unless pending_response

      begin
        read_more size
        finished = parser.finished?
      rescue EOFError
        finished = true
      end

      chunk = parser.chunk

      finish_response if finished

      chunk.to_s
    end

    # Reads data from socket up until headers are loaded
    def read_headers!
      read_more BUFFER_SIZE until parser.headers
      set_keep_alive

    rescue IOError, Errno::ECONNRESET, Errno::EPIPE => ex
      return if ex.is_a?(EOFError) && parser.headers
      raise IOError, "problem making HTTP request: #{ex}"
    end

    # Callback for when we've reached the end of a response
    def finish_response
      close unless keep_alive?

      parser.reset
      reset_timer

      @pending_response = nil
    end

    # Close the connection
    def close
      socket.close unless socket.closed?

      @pending_response = nil
      @pending_request = nil
    end

    # Whether we're keeping the conn alive
    def keep_alive?
      !!@keep_alive && !socket.closed?
    end

    # Whether our connection has expired
    def expired?
      !@conn_expires_at || @conn_expires_at < Time.now
    end

    def reset_timer
      @conn_expires_at = Time.now + keep_alive_timeout if persistent
    end

    private :reset_timer

    # Store whether the connection should be kept alive.
    # Once we reset the parser, we lose all of this state.
    def set_keep_alive
      return @keep_alive = false unless persistent

      # HTTP/1.0 requires opt in for Keep Alive
      if parser.http_version == "1.0"
        @keep_alive = parser.headers["Connection"] == HTTP::Client::KEEP_ALIVE

      # HTTP/1.1 is opt-out
      elsif parser.http_version == "1.1"
        @keep_alive = parser.headers["Connection"] != HTTP::Client::CLOSE

      # Anything else we assume doesn't supportit
      else
        @keep_alive = false
      end
    end

    private :set_keep_alive

    # Feeds some more data into parser
    def read_more(size)
      parser << socket.readpartial(size) unless parser.finished?
    end

    private :read_more
  end
end
