#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only App Store Connect client for diagnostics.
#   ruby asc.rb --credentials        resolve and validate the key (no key material printed)
#   ruby asc.rb GET '/v1/apps?limit=1'
# GET only: everything that writes lives in apply.rb behind --confirm.
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'asc'

begin
  if ARGV[0] == '--credentials'
    creds = Asc.credentials
    Asc.private_key(creds.p8_path)
    puts "key_id=#{creds.key_id}"
    puts "issuer_id=#{creds.issuer_id}"
    puts "p8_path=#{creds.p8_path}"
    puts "config_path=#{Asc::CONFIG_PATH}"
    exit 0
  end

  method, target = ARGV
  abort 'usage: ruby asc.rb --credentials | GET <path>' unless method&.upcase == 'GET' && target

  begin
    body = Asc.request(:get, target)
    puts 'HTTP 200'
    puts JSON.pretty_generate(body) if body
  rescue Asc::HttpError => e
    puts "HTTP #{e.code}"
    puts e.message
    exit 1
  end
rescue Asc::Error => e
  warn "ERROR: #{e.message}"
  exit 2
end
