# frozen_string_literal: true

# Where the bundled economic data lives; shared by plan.rb (reads) and
# refresh_data.rb (writes).
module Snapshots
  DATA_DIR = File.expand_path('../../references/data', __dir__)
  FILES = { big_mac: 'big-mac.csv', ppp: 'ppp.csv', gni: 'gni.csv' }.freeze
end
