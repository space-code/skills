#!/usr/bin/env ruby
# frozen_string_literal: true

# App Store Connect client: ES256 JWT, Ruby stdlib only. Never prints key material.
#
#   ruby asc.rb --credentials                      resolve and validate the key
#   ruby asc.rb GET '/v1/apps?limit=1' [--paginate]  --paginate follows links.next and merges pages
#   ruby asc.rb POST|PATCH|DELETE <path> [json | @file] --write
#
# Anything but GET needs --write. Add it only after the user approved the
# Price Proposal; without it the script refuses before touching the network.
require 'openssl'
require 'base64'
require 'json'
require 'net/http'
require 'uri'

module Asc
  API_HOST = 'api.appstoreconnect.apple.com'
  HOME_DIR = File.expand_path('~/.appstoreconnect')
  KEY_DIR = File.join(HOME_DIR, 'private_keys')
  CONFIG_PATH = File.join(HOME_DIR, 'config.json')
  KEY_NAME = /\AAuthKey_([A-Z0-9]+)\.p8\z/.freeze
  MAX_ATTEMPTS = 4

  class Error < StandardError; end

  class HttpError < Error
    attr_reader :code, :body

    def initialize(code, body)
      @code = code
      @body = body
      super("HTTP #{code}: #{detail(body)}")
    end

    private

    def detail(raw)
      err = JSON.parse(raw.to_s)['errors']&.first
      err ? [err['title'], err['detail']].compact.join(' - ') : raw.to_s[0, 200]
    rescue JSON::ParserError
      raw.to_s[0, 200]
    end
  end

  Credentials = Struct.new(:key_id, :issuer_id, :p8_path)
  # collect_points.rb calls the client from several threads
  CREDENTIALS_LOCK = Mutex.new
  TOKEN_LOCK = Mutex.new

  module_function

  # Env vars (ASC_KEY_ID, ASC_ISSUER_ID, ASC_P8) win over the key folder.
  def credentials
    CREDENTIALS_LOCK.synchronize { @credentials ||= resolve_credentials }
  end

  def resolve_credentials
    key_id = ENV['ASC_KEY_ID']
    p8 = ENV['ASC_P8'] ? File.expand_path(ENV['ASC_P8']) : locate_key(key_id)
    raise Error, "private key not found at #{p8}" unless File.file?(p8)

    key_id ||= File.basename(p8)[KEY_NAME, 1]
    raise Error, 'cannot read the key id from the file name; set ASC_KEY_ID' unless key_id

    issuer = ENV['ASC_ISSUER_ID'] || read_config['issuer_id']
    raise Error, "issuer id missing: put {\"issuer_id\": \"<UUID>\"} in #{CONFIG_PATH} or set ASC_ISSUER_ID" if issuer.to_s.empty?

    Credentials.new(key_id, issuer, p8)
  end

  def locate_key(key_id)
    return File.join(KEY_DIR, "AuthKey_#{key_id}.p8") if key_id

    keys = Dir.glob(File.join(KEY_DIR, 'AuthKey_*.p8')).sort
    raise Error, "no AuthKey_<KEY_ID>.p8 found in #{KEY_DIR}" if keys.empty?
    raise Error, "several keys in #{KEY_DIR}; set ASC_KEY_ID to pick one" if keys.size > 1

    keys.first
  end

  def read_config
    return {} unless File.file?(CONFIG_PATH)

    JSON.parse(File.read(CONFIG_PATH))
  rescue JSON::ParserError
    raise Error, "#{CONFIG_PATH} is not valid JSON"
  end

  def private_key(path)
    key = OpenSSL::PKey::EC.new(File.read(path))
    raise Error, 'key is public-only' unless key.private_key?
    raise Error, "key curve is #{key.group.curve_name}, expected prime256v1 (P-256)" unless key.group.curve_name == 'prime256v1'

    key
  rescue OpenSSL::PKey::PKeyError => e
    raise Error, "private key is not a valid EC key (#{e.class})"
  end

  def b64(data)
    Base64.urlsafe_encode64(data, padding: false)
  end

  def jwt(creds = credentials, now = Time.now.to_i)
    header = { alg: 'ES256', kid: creds.key_id, typ: 'JWT' }
    payload = { iss: creds.issuer_id, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }
    input = "#{b64(JSON.generate(header))}.#{b64(JSON.generate(payload))}"
    der = private_key(creds.p8_path).sign(OpenSSL::Digest::SHA256.new, input)
    # DER -> raw r||s (64 bytes), as JOSE ES256 requires
    asn = OpenSSL::ASN1.decode(der)
    raw = asn.value.map { |n| n.value.to_s(2).rjust(32, "\x00") }.join
    "#{input}.#{b64(raw)}"
  end

  def token
    TOKEN_LOCK.synchronize do
      now = Time.now.to_i
      if @token.nil? || now > @token_at + 900
        fresh = jwt(credentials, now)
        @token_at = now
        @token = fresh
      end
      @token
    end
  end

  def enc(value)
    URI.encode_www_form_component(value.to_s)
  end

  # path('/v1/x', 'filter[territory]' => 'USA') -> '/v1/x?filter%5Bterritory%5D=USA'
  def path(base, params = {})
    return base if params.empty?

    "#{base}#{base.include?('?') ? '&' : '?'}#{params.map { |k, v| "#{enc(k)}=#{enc(v)}" }.join('&')}"
  end

  def request(method, target, body = nil)
    uri = URI(target.start_with?('http') ? target : "https://#{API_HOST}#{target}")
    raise Error, "refusing to send the token to #{uri.host}" unless uri.host == API_HOST

    attempts = 0
    loop do
      attempts += 1
      res = http_call(uri, method, body)
      code = res.code.to_i
      if (code == 429 || code >= 500) && attempts < MAX_ATTEMPTS
        sleep((res['Retry-After'] || (2**attempts)).to_f)
        next
      end
      raise HttpError.new(code, res.body) unless code.between?(200, 299)

      return nil if res.body.to_s.empty?

      return parse_response(method, code, res.body)
    end
  end

  # A write that Apple accepted stays a success even when the body is not JSON
  # (a proxy page, say), so nobody retries it. A GET must return JSON: a page
  # without `data` would otherwise read as an empty list.
  def parse_response(method, code, body)
    JSON.parse(body)
  rescue JSON::ParserError
    raise Error, "HTTP #{code}: the response is not JSON" if method.to_s == 'get'

    { 'note' => "HTTP #{code}, the request succeeded but the response is not JSON", 'body' => body.to_s[0, 500] }
  end

  def http_call(uri, method, body)
    req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
    req['Authorization'] = "Bearer #{token}"
    req['Content-Type'] = 'application/json'
    req.body = JSON.generate(body) if body
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 90) { |h| h.request(req) }
  rescue SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
    raise Error, "network error: #{e.class}: #{e.message}"
  end

  # Follows links.next; returns {'data' => [...], 'included' => [...]}.
  def paginate(target)
    data = []
    included = []
    while target
      page = request(:get, target)
      data.concat(page['data'] || [])
      included.concat(page['included'] || [])
      target = page.dig('links', 'next')
    end
    { 'data' => data, 'included' => included }
  end

  def index_included(included)
    (included || []).each_with_object({}) { |r, h| h[[r['type'], r['id']]] = r }
  end

  USAGE = <<~TXT
    usage: ruby asc.rb --credentials
           ruby asc.rb GET <path> [--paginate]
           ruby asc.rb POST|PATCH|DELETE <path> [json | @file] --write
  TXT

  # Returns the exit code: 0 ok, 1 HTTP error, 2 usage or configuration error.
  def cli(argv)
    flags, args = argv.partition { |a| a.start_with?('--') }
    unknown = flags - %w[--credentials --paginate --write]
    return usage("unknown flag #{unknown.first}") unless unknown.empty?
    return print_credentials if flags.include?('--credentials')

    method, target, body = args
    method = method&.upcase
    return usage('need a method and a path') unless %w[GET POST PATCH DELETE].include?(method) && target
    return usage('refusing to write without --write; add it only after the user approved the Price Proposal') if method != 'GET' && !flags.include?('--write')

    begin
      payload = body && JSON.parse(body.start_with?('@') ? File.read(body[1..-1]) : body)
    rescue JSON::ParserError, Errno::ENOENT => e
      return usage("bad request body (#{e.class})")
    end
    result = if method == 'GET' && flags.include?('--paginate')
               paginate(target)
             else
               request(method.downcase.to_sym, target, payload)
             end
    puts method == 'GET' ? 'HTTP 200' : 'HTTP 2xx'
    puts JSON.pretty_generate(result) if result
    0
  rescue HttpError => e
    puts "HTTP #{e.code}"
    puts e.message
    1
  rescue Error => e
    warn "ERROR: #{e.message}"
    2
  end

  def usage(message)
    warn "ERROR: #{message}", USAGE
    2
  end

  def print_credentials
    creds = credentials
    private_key(creds.p8_path)
    puts "key_id=#{creds.key_id}", "issuer_id=#{creds.issuer_id}", "p8_path=#{creds.p8_path}", "config_path=#{CONFIG_PATH}"
    0
  end
end

exit(Asc.cli(ARGV)) if $PROGRAM_NAME == __FILE__
