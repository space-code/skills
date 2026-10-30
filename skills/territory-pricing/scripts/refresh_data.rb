#!/usr/bin/env ruby
# frozen_string_literal: true

# Refreshes the bundled snapshots in references/data/ from the live sources.
# Usage: ruby refresh_data.rb
$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'data_sources'

%i[big_mac ppp gni].each do |name|
  values, meta = DataSources.send("fetch_#{name}")
  DataSources.write_snapshot(name, values, meta['as_of'])
  puts "#{name}: #{values.size} countries, as of #{meta['as_of']}"
rescue StandardError => e
  warn "#{name}: FAILED (#{e.class}: #{e.message}); snapshot left unchanged"
  exit 1
end
