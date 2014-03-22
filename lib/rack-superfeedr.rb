require 'base64'
require 'typhoeus'
require 'json'
require 'nokogiri'


module Rack


  ##
  # This is a Rack Middleware that can be used in your rack-compatible web framework (Rails, Sinatra...) to perform subscriptions over at superfeedr
  # using the PubSubHubbub API.
  class Superfeedr

    SUPERFEEDR_ENDPOINT = "https://push.superfeedr.com"

    ##
    # Shows the latest error received by the API.
    # Useful when a subscription or unsubscription request fails.
    def error
      @error
    end

    ##
    # Subscribe you to a url. id is optional, but recommanded has a unique identifier for this url. It will be used to help you identify which feed
    # is concerned by a notification.
    # The optional block will be called to let you confirm the subscription (or not).
    # It returns true if the subscription was successful (or will be confirmed if you used async => true in the options), false otherwise.
    # You can also pass an opts third argument that will be merged with the options used in Typhoeus's Request (https://github.com/dbalatero/typhoeus)
    # A useful option is :verbose => true for example.
    def subscribe(url, id = nil, opts = {}, &block)
      feed_id = "#{id ? id : Base64.urlsafe_encode64(url)}"
      if block
        @verifications[feed_id] ||= {}
        @verifications[feed_id]['subscribe'] = block
      end
      endpoint = opts[:hub] || SUPERFEEDR_ENDPOINT
      opts.delete(:hub)

      if endpoint == SUPERFEEDR_ENDPOINT
        opts[:userpwd] = "#{@params[:login]}:#{@params[:password]}"
      end

      response = ::Typhoeus::Request.post(endpoint,
      opts.merge({
        :params => {
          :'hub.mode' => 'subscribe',
          :'hub.verify' => @params[:async] ? 'async' : 'sync',
          :'hub.topic' => url,
          :'hub.callback' =>  generate_callback(url, feed_id)
        },
        :headers => {
          :Accept => @params[:format] == "json" ? "application/json" : "application/atom+xml"
        }
      }))

      @error = response.body
      @params[:async] && response.code == 202 || response.code == 204 # We return true to indicate the status.
    end

    ##
    # Unsubscribes a url. If you used an id for the subscription, you need to use _the same_.
    # The optional block will be called to let you confirm the subscription (or not). This is not applicable for if you use params[:async] => true
    # It returns true if the unsubscription was successful (or will be confirmed if you used async => true in the options), false otherwise
    # You can also pass an opts third argument that will be merged with the options used in Typhoeus's Request (https://github.com/dbalatero/typhoeus)
    # A useful option is :verbose => true for example.
    def unsubscribe(url, id = nil, opts = {}, &block)
      feed_id = "#{id ? id : Base64.urlsafe_encode64(url)}"
      if block
        @verifications[feed_id] ||= {}
        @verifications[feed_id]['unsubscribe'] = block
      end
      response = ::Typhoeus::Request.post(SUPERFEEDR_ENDPOINT,
      opts.merge({
        :params => {
          :'hub.mode' => 'unsubscribe',
          :'hub.verify' => @params[:async] ? 'async' : 'sync',
          :'hub.topic' => url,
          :'hub.callback' =>  generate_callback(url, feed_id)
        },
        :userpwd => "#{@params[:login]}:#{@params[:password]}"
      }))
      @error = response.body
      @params[:async] && response.code == 202 || response.code == 204 # We return true to indicate the status.
    end

    ##
    # Retrieving Entries with PubSubHubbub
    def retrieve(url, id = nil, opts = {}, &block)
      feed_id = "#{id ? id : Base64.urlsafe_encode64(url)}"
      if block
        @verifications[feed_id] ||= {}
        @verifications[feed_id]['retrieve'] = block
      end
      endpoint = opts[:hub] || SUPERFEEDR_ENDPOINT
      opts.delete(:hub)

      if endpoint == SUPERFEEDR_ENDPOINT
        opts[:userpwd] = "#{@params[:login]}:#{@params[:password]}"
      end

      response = ::Typhoeus::Request.get(endpoint,
                                          opts.merge({
                                                         :params => {
                                                             :'hub.mode' => 'retrieve',
                                                             :'hub.count' => opts[:count] ? opts[:count] : 10,
                                                             :'hub.topic' => url,
                                                             :'hub.callback' =>  generate_callback(url, feed_id)
                                                         },
                                                         :headers => {
                                                             :Accept => @params[:format] == "json" ? "application/json" : "application/atom+xml"
                                                         }
                                                     }))

      # Let's now send that data back to the user.
      @callback.call(response.body, feed_id)

      response.code == 200 || response.code == 304 # We return true to indicate the status.
    end

    ##
    # This allows you to define what happens with the notifications. The block passed in argument is called for each notification, with 2 arguments
    # - the payload itself (ATOM or JSON, based on what you selected in the params)
    # - the id for the feed, if you used any upon subscription
    def on_notification(&block)
      @callback = block
    end

    ##
    # When using this Rack, you need to supply the following params (2nd argument):
    # - :host (the host for your web app. Used to build the callback urls.)
    # - :login
    # - :password
    # - :format (atom|json, atom being default)
    # - :async (true|false), false is default. You need to set that to false if you're using platforms like Heroku that may disallow concurrency.
    def initialize(app, params = {}, &block)
      raise ArgumentError, 'Missing :host in params' unless params[:host]
      raise ArgumentError, 'Missing :login in params' unless params[:login]
      raise ArgumentError, 'Missing :password in params' unless params[:password]
      @callback = Proc.new { |notification, feed_id|
        # Bh default, do nothing
      }
      @verifications = {}
      @params = params
      @params[:port] = 80 unless params[:port]
      @app = app
      @base_path = params[:base_path] || '/superfeedr/feed/'
      block.call(self)
      self
    end

    def reset(params = {})
      raise ArgumentError, 'Missing :host in params' unless params[:host]
      raise ArgumentError, 'Missing :login in params' unless params[:login]
      raise ArgumentError, 'Missing :password in params' unless params[:password]
      @params = params
    end

    def params
      @params
    end

    def call(env)
      req = Rack::Request.new(env)
      if env['REQUEST_METHOD'] == 'GET' && feed_id = env['PATH_INFO'].match(/#{@base_path}(.*)/)
        # Verification of intent!
        if @verifications[feed_id[1]] && verification = @verifications[feed_id[1]][req.params['hub.mode']]
          # Check with the user
          if verification.call(req.params['hub.topic'], feed_id[1])
            Rack::Response.new(req.params['hub.challenge'], 200).finish
          else
            Rack::Response.new("not valid", 404).finish
          end
        else
          # By default, we accept all
          Rack::Response.new(req.params['hub.challenge'], 200).finish
        end
      elsif env['REQUEST_METHOD'] == 'POST' && feed_id = env['PATH_INFO'].match(/#{@base_path}(.*)/)
        # Notification
        content = nil
        # Body is a stream, not a string, so capture it once and save it
        body = req.body.read
        if env["CONTENT_TYPE"]
          content_type = env["CONTENT_TYPE"].split(";").first
        else
          content_type = "application/atom+xml" #default?
        end
        if content_type == "application/json"
          # Let's parse the body as JSON
          content = JSON.parse(body)
        elsif content_type == "application/atom+xml"
          # Let's parse the body as ATOM using nokogiri
          content = Nokogiri.XML(body)
        end
        # Let's now send that data back to the user.
        info = Hashie::Mash.new(req: req, body: body)
        if !@callback.call(content, feed_id[1], info)
          # We need to unsubscribe the user
        end
        Rack::Response.new("Thanks!", 200).finish
      else
        @app.call(env)
      end
    end

    protected

    def generate_callback(url, feed_id)
      scheme = params[:scheme] || 'http'
      URI::HTTP.build({:scheme => scheme, :host => @params[:host], :path => "#{@base_path}#{feed_id}", :port => @params[:port] }).to_s
    end

  end

end
