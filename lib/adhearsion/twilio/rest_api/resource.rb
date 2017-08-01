require_relative "../util/url"

class Adhearsion::Twilio::RestApi::Resource
  attr_accessor :options

  def initialize(options = {})
    self.options = options
  end

  private

  def log(*args)
    options[:logger] && options[:logger].public_send(*args)
  end

  def configuration
    @configuration ||= Adhearsion::Twilio::Configuration.new
  end

  def extract_auth(url)
    Adhearsion::Twilio::Util::Url.new(url).extract_auth
  end
end
