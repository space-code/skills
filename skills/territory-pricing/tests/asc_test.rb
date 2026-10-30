# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../scripts/asc'
require 'open3'
require 'rbconfig'
require 'openssl'
require 'tmpdir'

class AscTest < Minitest::Test
  def with_key(pem)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'AuthKey_ABCDE12345.p8')
      File.write(path, pem)
      yield path
    end
  end

  def test_jwt_is_a_valid_es256_token
    key = OpenSSL::PKey::EC.generate('prime256v1')
    with_key(key.to_pem) do |path|
      token = Asc.jwt(Asc::Credentials.new('ABCDE12345', 'issuer-uuid', path), 1_700_000_000)
      header, payload, signature = token.split('.')
      assert_equal({ 'alg' => 'ES256', 'kid' => 'ABCDE12345', 'typ' => 'JWT' }, JSON.parse(Base64.urlsafe_decode64(header)))
      claims = JSON.parse(Base64.urlsafe_decode64(payload))
      assert_equal 'issuer-uuid', claims['iss']
      assert_equal 'appstoreconnect-v1', claims['aud']
      assert_equal 1_700_001_200, claims['exp']
      raw = Base64.urlsafe_decode64(signature)
      assert_equal 64, raw.bytesize
      der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[0, 32], 2)),
                                     OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[32, 32], 2))]).to_der
      assert key.verify(OpenSSL::Digest::SHA256.new, der, "#{header}.#{payload}")
    end
  end

  def test_rejects_keys_that_are_not_p256
    with_key(OpenSSL::PKey::EC.generate('secp384r1').to_pem) do |path|
      assert_raises(Asc::Error) { Asc.private_key(path) }
    end
  end

  def test_rejects_non_ec_keys
    with_key(OpenSSL::PKey::RSA.new(2048).to_pem) do |path|
      assert_raises(Asc::Error) { Asc.private_key(path) }
    end
  end

  def test_path_encodes_brackets
    assert_equal '/v1/x?filter%5Bterritory%5D=USA&limit=200', Asc.path('/v1/x', 'filter[territory]' => 'USA', 'limit' => 200)
  end

  def test_path_extends_an_existing_query_with_an_ampersand
    assert_equal '/v1/x?include=territory&limit=200', Asc.path('/v1/x?include=territory', 'limit' => 200)
  end

  def test_token_is_never_sent_to_another_host
    assert_raises(Asc::Error) { Asc.request(:get, 'https://example.com/v1/apps') }
  end

  ASC = File.expand_path('../scripts/asc.rb', __dir__)

  def run_asc(*args)
    Open3.capture3({ 'ASC_KEY_ID' => nil, 'ASC_ISSUER_ID' => nil, 'ASC_P8' => nil, 'HOME' => Dir.tmpdir }, RbConfig.ruby, ASC, *args)
  end

  def test_writes_are_refused_without_the_write_flag
    %w[POST PATCH DELETE].each do |method|
      _, err, status = run_asc(method, '/v1/subscriptionPrices', '{}')
      assert_equal 2, status.exitstatus, method
      assert_includes err, '--write'
    end
  end

  def test_write_guard_runs_before_credentials_are_read
    _, err, status = run_asc('POST', '/v1/x', '{}')
    refute_includes err, 'AuthKey', 'no key lookup should happen for a refused write'
    assert_equal 2, status.exitstatus
  end

  def test_unknown_flags_and_methods_are_rejected
    assert_equal 2, run_asc('GET', '/v1/apps', '--bogus').last.exitstatus
    assert_equal 2, run_asc('PUT', '/v1/apps', '--write').last.exitstatus
  end
end
