# frozen_string_literal: true

require_relative 'test_helper'
require 'asc'
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
    key = OpenSSL::PKey::EC.new('prime256v1').generate_key
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
      public_key = OpenSSL::PKey::EC.new(key.public_key.group)
      public_key.public_key = key.public_key
      assert public_key.verify(OpenSSL::Digest::SHA256.new, der, "#{header}.#{payload}")
    end
  end

  def test_rejects_keys_that_are_not_p256
    with_key(OpenSSL::PKey::EC.new('secp384r1').generate_key.to_pem) do |path|
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

  def test_token_is_never_sent_to_another_host
    assert_raises(Asc::Error) { Asc.request(:get, 'https://example.com/v1/apps') }
  end
end
