#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes the current per-territory prices of one product to a JSON file.
#   ruby snapshot.rb --kind subscription --id 6447497832 --out before.json
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'optparse'
require 'json'
require 'products'

opts = {}
OptionParser.new do |o|
  o.on('--kind KIND', Products::KINDS) { |v| opts[:kind] = v }
  o.on('--id ID') { |v| opts[:id] = v }
  o.on('--out FILE') { |v| opts[:out] = v }
end.parse!
abort 'usage: ruby snapshot.rb --kind app|iap|subscription --id ID --out FILE' unless opts.values_at(:kind, :id, :out).all?

begin
  snap = Products.build(opts[:kind], opts[:id]).snapshot
  File.write(opts[:out], JSON.pretty_generate(snap))
  puts "#{snap['prices'].size} territories written to #{opts[:out]}"
rescue Asc::Error => e
  abort "ERROR: #{e.message}"
end
