# Copyright (c) 2009-2011 VMware, Inc.
require "sinatra"
require "nats/client"
require "redis"
require "json"

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', 'mysql')

module VCAP
  module Services
    module Serialization
    end
  end
end

class VCAP::Services::Serialization::Server < Sinatra::Base

  REQ_OPTS = %w(serialization_base_dir mbus port external_uri redis).map {|o| o.to_sym}

  set :show_exceptions, false

  def initialize(opts)
    super
    missing_opts = REQ_OPTS.select {|o| !opts.has_key? o}
    raise ArgumentError, "Missing options: #{missing_opts.join(', ')}" unless missing_opts.empty?
    @opts = opts
    @logger = opts[:logger] || make_logger
    @nginx = opts[:nginx]
    @host = opts[:host]
    @port = opts[:port]
    @external_uri = opts[:external_uri]
    @router_start_channel  = nil
    @base_dir = opts[:serialization_base_dir]
    NATS.on_error do |e|
      if e.kind_of? NATS::ConnectError
        @logger.error("EXITING! NATS connection failed: #{e}")
        exit
      else
        @logger.error("NATS problem, #{e}")
      end
    end
    @nats = NATS.connect(:uri => opts[:mbus]) {
      on_connect_nats
    }
    Kernel.at_exit do
      if EM.reactor_running?
        send_deactivation_notice(false)
      else
        EM.run { send_deactivation_notice }
      end
    end

    @router_register_json  = {
      :host => @host,
      :port => ( @nginx ? @nginx["nginx_port"] : @port),
      :uris => [ @external_uri ],
      :tags => {:components =>  "SerializationDataServer"},
    }.to_json
  end

  def on_connect_nats()
    @logger.info("Register download server uri : #{@router_register_json}")
    @nats.publish('router.register', @router_register_json)
    @router_start_channel = @nats.subscribe('router.start') { @nats.publish('router.register', @router_register_json)}
    @redis = connect_redis
  end

  def connect_redis()
    redis_config = %w(host port password).inject({}){|res, o| res[o.to_sym] = @opts[:redis][o]; res}
    Redis.new(redis_config)
  end

  def make_logger()
    logger = Logger.new(STDOUT)
    logger.level = Logger::DEBUG
    logger
  end

  # Unrigister external uri
  def send_deactivation_notice(stop_event_loop=true)
    @nats.unsubscribe(@router_start_channel) if @router_start_channel
    @logger.debug("Unregister uri: #{@router_register_json}")
    @nats.publish("router.unregister", @router_register_json)
    @nats.close
    EM.stop if stop_event_loop
  end

  def redis_key(service, service_id)
    "vcap:serialization:#{service}:token:#{service_id}"
  end

  def file_path(service, id)
    File.join(@base_dir, "serialize", service, id[0,2], id[2,2], id[4,2], id, "#{id}.gz")
  end

  def nginx_path(service, id)
    File.join(@nginx["nginx_path"], "serialize", service, id[0,2], id[2,2], id[4,2], id, "#{id}.gz")
  end

  get "/serialized/:service/:service_id" do
    token = params[:token]
    error(403) unless token
    service = params[:service]
    service_id = params[:service_id]
    @logger.debug("Get serialized data for service=#{service}, service_id=#{service_id}")
    key = redis_key(service, service_id)
    result = @redis.get(key)
    error(404) unless result
    error(403) unless token == result
    path = file_path(service, service_id)
    if (File.exists? path)
    if @nginx
      status 200
      content_type "application/octet-stream"
      path = nginx_path(service, service_id)
      @logger.info("Serve file using nginx: #{path}")
      response["X-Accel-Redirect"] = path
    else
      @logger.info("Serve file: #{path}")
      send_file(path)
    end
    else
      error(404)
    end
  end

  not_found do
    halt 404
  end

end
