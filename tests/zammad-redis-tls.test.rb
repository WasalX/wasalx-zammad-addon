# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Mohammed Altoyan <mohammedaltoyan@gmail.com>
require 'pathname'
require 'tmpdir'
require 'fileutils'
module Rails
  def self.root = Pathname.new(ENV.fetch('WASALX_TEST_ROOT'))
end
module Zammad
  module Service
    class Redis
      def self.config = { driver: :hiredis, url: ENV.fetch('REDIS_URL') }
    end
  end
end

Dir.mktmpdir('wasalx-redis-tls-') do |root|
  ENV['WASALX_TEST_ROOT'] = root
  FileUtils.mkdir_p(File.join(root, 'lib/zammad/service'))
  File.write(File.join(root, 'lib/zammad/service/redis.rb'), '')
  load(ARGV[0] || File.expand_path('../infra/docker/full/zammad/redis-tls.rb', __dir__))
  ENV['REDIS_URL'] = 'redis://redis:6379'
  raise unless Zammad::Service::Redis.config == { driver: :hiredis, url: ENV['REDIS_URL'] }
  ENV['REDIS_URL'] = 'rediss://user:private@redis:6379/0'
  ca = File.join(root, 'ca.crt')
  File.write(ca, 'fixture')
  ENV['SSL_CERT_FILE'] = ca
  raise unless Zammad::Service::Redis.config[:driver] == :ruby
  raise unless Zammad::Service::Redis.config[:ssl_params] == { ca_file: ca, verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true }
  [nil, '', 'relative.crt', File.join(root, 'missing.crt')].each do |invalid|
    ENV['SSL_CERT_FILE'] = invalid
    begin
      Zammad::Service::Redis.config
    rescue ArgumentError => error
      raise unless error.message == 'Invalid Zammad Redis TLS configuration'
      next
    end
    raise 'Invalid TLS configuration was accepted'
  end
end
puts 'Redis TLS configuration contract passed'
