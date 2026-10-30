# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../scripts/asc'
require 'tmpdir'
require 'stringio'

# collect_points.rb with Asc.paginate stubbed: batching, resume, failure handling.
class CollectPointsTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/collect_points.rb', __dir__)

  def setup
    @original = Asc.method(:paginate)
    @requested = Queue.new
    @fail = []
    requested = @requested
    fail_on = @fail
    Asc.singleton_class.send(:define_method, :paginate) do |target|
      territory = target[/territory%5D=(\w+)/, 1]
      requested << territory
      raise Asc::Error, 'HTTP 500: boom' if fail_on.include?(territory)

      { 'data' => [{ 'id' => "#{territory}-1", 'attributes' => { 'customerPrice' => '9.99' } }] }
    end
  end

  def teardown
    Asc.singleton_class.send(:define_method, :paginate, @original)
  end

  def run_script(dir, batch: '40')
    ENV['COLLECT_BATCH'] = batch
    out = StringIO.new
    status = nil
    $stdout = out
    begin
      ARGV.replace([dir, '/v1/subscriptions/42/pricePoints'])
      load SCRIPT
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = STDOUT
      ENV.delete('COLLECT_BATCH')
    end
    [out.string, status]
  end

  def with_run(territories)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'territories.json'), JSON.generate(territories))
      yield dir
    end
  end

  def test_one_batch_saves_that_many_territories_then_resumes
    with_run(%w[USA BRA IND JPN DEU]) do |dir|
      out, status = run_script(dir, batch: '2')
      assert_equal 0, status
      assert_includes out, '2/5 territories saved'
      assert_includes out, 'run again: 3 left'
      out, = run_script(dir, batch: '2')
      assert_includes out, '4/5 territories saved'
      out, = run_script(dir, batch: '2')
      assert_includes out, 'done'
      assert_equal 5, Dir[File.join(dir, 'points', '*.json')].size
    end
  end

  def test_saved_territories_are_not_requested_again
    with_run(%w[USA BRA]) do |dir|
      run_script(dir)
      @requested.clear
      run_script(dir)
      assert_equal 0, @requested.size
    end
  end

  def test_points_are_stored_as_numbers
    with_run(%w[USA]) do |dir|
      run_script(dir)
      assert_equal [{ 'id' => 'USA-1', 'price' => 9.99 }], JSON.parse(File.read(File.join(dir, 'points', 'USA.json')))
    end
  end

  def test_a_failed_territory_is_reported_and_the_others_are_kept
    with_run(%w[USA BAD BRA]) do |dir|
      @fail << 'BAD'
      out, status = run_script(dir)
      assert_equal 1, status
      assert_includes out, 'failed: BAD: HTTP 500: boom'
      assert_includes out, '2/3 territories saved'
      refute File.exist?(File.join(dir, 'points', 'BAD.json'))
      @fail.clear
      out, status = run_script(dir)
      assert_equal 0, status
      assert_includes out, 'done'
    end
  end
end
