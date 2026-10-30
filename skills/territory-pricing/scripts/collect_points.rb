#!/usr/bin/env ruby
# frozen_string_literal: true

# Reads the price points of every territory in short, resumable batches.
# A subscription has about 800 price points per territory and Apple returns
# 200 per page, so a full sweep is ~700 requests: too long for one shell
# command (10 minute limit). Each run handles one batch and saves every
# territory to its own file; run it again until it prints "done".
#
#   ruby collect_points.rb RUN_DIR POINTS_PATH
#
# POINTS_PATH is the product's price-points endpoint, for example
#   /v1/subscriptions/<ID>/pricePoints
#   /v1/apps/<ID>/appPricePoints
#   /v2/inAppPurchases/<ID>/pricePoints
# RUN_DIR/territories.json lists the territory codes to read: ["USA", "BRA", ...].
# Output: RUN_DIR/points/<TERRITORY>.json = [{"id", "price"}, ...]
require 'json'
require 'fileutils'
require_relative 'asc'

batch = Integer(ENV.fetch('COLLECT_BATCH', 40)) # territories per run, about 30 s
threads = Integer(ENV.fetch('COLLECT_THREADS', 6)) # more threads mostly buys HTTP 429 answers

run, path = ARGV
abort 'usage: ruby collect_points.rb RUN_DIR POINTS_PATH' unless run && path

dir = File.join(run, 'points')
FileUtils.mkdir_p(dir)
territories = JSON.parse(File.read(File.join(run, 'territories.json')))
saved = ->(t) { File.exist?(File.join(dir, "#{t}.json")) }
queue = Queue.new
territories.reject(&saved).first(batch).each { |t| queue << t }
failed = Queue.new

Array.new(threads) do
  Thread.new do
    loop do
      t = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      begin
        page = Asc.paginate(Asc.path(path, 'filter[territory]' => t, 'limit' => 200))
        points = page['data'].map { |d| { 'id' => d['id'], 'price' => d.dig('attributes', 'customerPrice').to_f } }
        File.write(File.join(dir, "#{t}.tmp"), JSON.generate(points))
        File.rename(File.join(dir, "#{t}.tmp"), File.join(dir, "#{t}.json"))
      rescue Asc::Error => e
        failed << "#{t}: #{e.message}"
      end
    end
  end
end.each(&:join)

left = territories.reject(&saved).size
failures = Array.new(failed.size) { failed.pop }
puts "#{territories.size - left}/#{territories.size} territories saved"
puts "failed: #{failures.join('; ')}" unless failures.empty?
puts(left.zero? ? 'done' : "run again: #{left} left")
exit(failures.empty? ? 0 : 1)
