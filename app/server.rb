require "socket"

require 'zlib'

require "stringio"

require "optparse"

HTTP_STATUS = { 200 => "OK", 404 => "Not Found", 201 => "Created" }.freeze

OPTIONS = {}

OptionParser.new do |opts|

  opts.on("--directory DIRECTORY", "Directory to serve") do |directory|

    path = Pathname(directory)

    raise OptionParser::InvalidArgument unless path.exist? && path.directory?

    OPTIONS[:directory] = directory

  end

end.parse!

OPTIONS.freeze

def read_header_lines(client_socket)

  lines = []

  while (line = client_socket.gets) != "\r\n"

    lines << line.chomp # chomp removes the trailing newline

  end

  lines

end

def parse_request(raw_request_lines)

  method, path, version = raw_request_lines.first.split

  out = { method: method, path: path }

  raw_request_lines.drop(1).each do |header|

    key, value = header.split(": ", 2).map(&:strip)

    out[key] = value

  end

  out

end

def generate_response(client_socket, request)

  method = request[:method]

  path = request[:path]

  headers = { "Content-Type" => "text/plain" }

  if request.fetch("Accept-Encoding", "").include?('gzip')

    headers['Content-Encoding'] = 'gzip'

  end

  puts "Request: #{method} #{path}"

  case [method, path]

  in ["GET", "/"]

    [200, headers, []]

  in ["GET", %r{^/echo/(.*)$} => echo_message]

    echo_message = echo_message[6..] || ""

    headers["Content-Length"] = echo_message.length.to_s

    if headers['Content-Encoding'] == "gzip"
      compressed_data = enconding_string(echo_message)
      headers["Content-Length"] = compressed_data.length.to_s
      return [200, headers, [compressed_data].reject(&:empty?)]
    end

    return [200, headers, [echo_message].reject(&:empty?)]

  in ["GET", "/user-agent"]

    body = request.fetch("User-Agent", "")

    headers["Content-Length"] = body.length.to_s

    [200, headers, [body].reject(&:empty?)]

  in ["GET", %r{^/files/(.*)$} => filename]

    if (file_path = validate(filename[7..]))

      file_size = File.size(file_path)

      file_content = File.read(file_path)

      [

        200,

        headers.merge("Content-Length" => file_size.to_s,

                      "Content-Type" => "application/octet-stream"),

        [file_content],

      ]

    else

      [404, headers, []]

    end

  in ["POST", %r{^/files/(.*)$} => filename]

    file_path = File.join(OPTIONS[:directory], filename[7..])

    content_length = request["Content-Length"]

    body = client_socket.read(content_length.to_i)

    File.write(file_path, body)

    [201, headers, []]

  else

    [404, headers, []]

  end

end

def stringify_response(response)

  status_code, headers, body = response

  newline = "\r\n".freeze

  StringIO.open do |builder|

    builder.write "HTTP/1.1 #{status_code} #{HTTP_STATUS[status_code]}"

    builder.write(newline)

    headers.each do |key, value|

      builder.write "#{key}: #{value}"

      builder.write(newline)

    end

    builder.write(newline)

    body.each do

      builder.write(_1)

      builder.write(newline)

    end

    builder.string

  end

end

# nil or valid file path
def enconding_string(value)
  buffer = StringIO.new

  gzip_writer = Zlib::GzipWriter.new(buffer)

  gzip_writer.write(value)

  gzip_writer.close

  buffer.string
end

def validate(filename)

  dir = OPTIONS.fetch(:directory) do

    raise ArgumentError, "no directory was provided at server start"

  end

  return unless Dir.children(dir).include?(filename)

  file = File.join(dir, filename)

  return unless File.file?(file) && File.readable?(file)

  file

end

server = TCPServer.new("localhost", 4221)

loop do

  Thread.start(server.accept) do |client_socket, client_address|

    puts "Connection from: #{client_address}"

    raw_request_lines = read_header_lines(client_socket)

    headers = parse_request(raw_request_lines)

    response = generate_response(client_socket, headers)

    client_socket.puts stringify_response(response)

  rescue StandardError => e

    puts "Error: #{e.inspect}"

  ensure

    client_socket.close

  end

end
