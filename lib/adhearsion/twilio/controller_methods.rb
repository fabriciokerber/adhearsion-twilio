module Adhearsion
  module Twilio
    TwimlError = Class.new(Adhearsion::Error) # Represents a failure to pass valid TwiML

    TWILIO_CALL_STATUSES = {
      :no_answer => "no-answer",
      :answer => "completed",
      :timeout => "no-answer",
      :error => "failed",
      :in_progress => "in-progress"
    }

    INFINITY = 100
    SLEEP_BETWEEN_REDIRECTS = 1
    DEFAULT_AUTH_TOKEN = "ADHEARSION_TWILIO_AUTH_TOKEN"

    module ControllerMethods
      extend ActiveSupport::Concern

      included do
        after :twilio_hangup
      end

      private

      def answered?
        !!@answered
      end

      def answer!
        answer unless answered?
        @answered = true
      end

      def notify_voice_request_url
        execute_twiml(notify_http(voice_request_url, voice_request_method, :in_progress))
      end

      def redirect(url = nil, options = {})
        execute_twiml(
          notify_http(
            URI.join(@last_request_url, url.to_s).to_s,
            options.delete("method") || "post",
            :in_progress, options
          )
        )
      end

      def notify_status_callback_url
        notify_http(
          status_callback_url,
          status_callback_method,
          answered? ? :answer : :no_answer,
          "CallDuration" => call.duration.to_i,
        ) if status_callback_url.present?
      end

      def notify_http(url, method, status, options = {})
        basic_auth, sanitized_url = extract_auth_from_url(url)
        @last_request_url = sanitized_url
        request_body = {"CallStatus" => TWILIO_CALL_STATUSES[status]}.merge(build_request_body).merge(options)
        headers = build_twilio_signature_header(sanitized_url, request_body)

        request_options = {
          :body => request_body,
          :headers => headers
        }

        request_options.merge!(:basic_auth => basic_auth) if basic_auth.any?

        HTTParty.send(
          method.downcase,
          sanitized_url,
          request_options
        ).body
      end

      def build_request_body
        {
          "From" => normalized_from,
          "To" => normalized_to,
          "CallSid" => call.id,
          "ApiVersion" => api_version
        }
      end

      def build_twilio_signature_header(url, params)
        {"X-Twilio-Signature" => twilio_request_validator.build_signature_for(url, params)}
      end

      def twilio_request_validator
        @twilio_request_validator ||= Adhearsion::Twilio::Util::RequestValidator.new(auth_token)
      end

      def execute_twiml(response)
        redirection = nil
        with_twiml(response) do |node|
          content = node.content
          options = twilio_options(node)
          case node.name
          when 'Reject'
            execute_twiml_verb(:reject, false, options)
            break
          when 'Play'
            execute_twiml_verb(:play, true, content, options)
          when 'Gather'
            break if redirection = execute_twiml_verb(:gather, true, node, options)
          when 'Redirect'
            redirection = execute_twiml_verb(:redirect, false, content, options)
            break
          when 'Hangup'
            break
          when 'Say'
            execute_twiml_verb(:say, true, content, options)
          when 'Pause'
            not_yet_supported!
          when 'Bridge'
            not_yet_supported!
          when 'Dial'
            break if redirection = execute_twiml_verb(:dial, true, node, options)
          else
            raise(ArgumentError, "Invalid element '#{node.name}'")
          end
        end
        redirection ? redirect(*redirection) : hangup
      end

      def execute_twiml_verb(verb, answer_call, *args)
        answer! if answer_call
        send("twilio_#{verb}", *args)
      end

      def twilio_reject(options = {})
        reject(options["reason"] == "busy" ? :busy : :decline)
      end

      def twilio_hangup
        notify_status_callback_url
      end

      def twilio_redirect(url, options = {})
        raise(TwimlError, "invalid redirect url") if url && url.empty?
        sleep(SLEEP_BETWEEN_REDIRECTS)
        [url, options]
      end

      def twilio_gather(node, options = {})
        ask_params = []
        ask_options = {}

        node.children.each do |nested_verb_node|
          verb = nested_verb_node.name
          raise(
            TwimlError,
            "Nested verb '<#{verb}>' not allowed within '<#{node.name}>'"
          ) unless ["Say", "Play", "Pause"].include?(verb)

          nested_verb_options = twilio_options(nested_verb_node)
          output_count = twilio_loop(nested_verb_options, :finite => true).count
          ask_options.merge!(send("options_for_twilio_#{verb.downcase}", nested_verb_options))
          ask_params << Array.new(output_count, nested_verb_node.content)
        end

        ask_options.merge!(:timeout => (options["timeout"] || 5).to_i.seconds)

        if options["finishOnKey"]
          ask_options.merge!(
            :terminator => options["finishOnKey"]
          ) if options["finishOnKey"] =~ /^(?:\d|\*|\#)$/
        else
          ask_options.merge!(:terminator => "#")
        end

        ask_options.merge!(:limit => options["numDigits"].to_i) if options["numDigits"]

        ask_params << nil if ask_params.blank?
        result = ask(*ask_params.flatten, ask_options)
        digits = result.response

        [
          options["action"],
          {
            "Digits" => digits, "method" => options["method"]
          }
        ] if digits.present?
      end

      def twilio_say(words, options = {})
        params = options_for_twilio_say(options)
        twilio_loop(options).each do
          say(words, params)
        end
      end

      def options_for_twilio_say(options = {})
        params = {}
        voice = options["voice"].to_s.downcase == "woman" ? config.default_female_voice : config.default_male_voice
        params[:voice] = voice if voice
        params
      end

      def options_for_twilio_play(options = {})
        {}
      end

      def options_for_twilio_dial(options = {})
        global = options.delete(:global)
        global = true unless global == false
        params = {}
        params[:from] = options["callerId"] if options["callerId"]
        params[:ringback] = options["ringback"] if options["ringback"]
        params[:for] = (options["timeout"] ? options["timeout"].to_i.seconds : 30.seconds) if global
        params
      end

      def twilio_dial(node, options = {})
        params = options_for_twilio_dial(options)
        to = {}

        node.children.each do |nested_noun_node|
          break if nested_noun_node.text?
          noun = nested_noun_node.name
          raise(
            TwimlError,
            "Nested noun '<#{noun}>' not allowed within '<#{node.name}>'"
          ) unless ["Number"].include?(noun)

          nested_noun_options = twilio_options(nested_noun_node)
          specific_dial_options = options_for_twilio_dial(nested_noun_options.merge(:global => false))

          to[nested_noun_node.content.strip] = specific_dial_options
        end

        to = node.content if to.empty?

        dial_status = dial(to, params)

        dial_call_status_options = {
          "DialCallStatus" => TWILIO_CALL_STATUSES[dial_status.result]
        }

        # try to find the joined call
        outbound_call = dial_status.joins.select do |outbound_leg, join_status|
          join_status.result == :joined
        end.keys.first

        dial_call_status_options.merge!(
          "DialCallSid" => outbound_call.id,
          "DialCallDuration" => dial_status.joins[outbound_call].duration.to_i
        ) if outbound_call

        [
          options["action"],
          {
            "method" => options["method"],
          }.merge(dial_call_status_options)
        ] if options["action"]
      end

      def twilio_play(path, options = {})
        twilio_loop(options).each do
          play_audio(path, options_for_twilio_play)
        end
      end

      def parse_twiml(xml)
        doc = ::Nokogiri::XML(xml) do |config|
          config.options = Nokogiri::XML::ParseOptions::NOBLANKS
        end
        raise doc.errors.first if doc.errors.length > 0
        raise(ArgumentError, "The root element must be the '<Response>' element") unless doc.root.name == "Response"
        doc.root.children
      end

      def with_twiml(raw_response, &block)
        doc = parse_twiml(raw_response)
        doc.each do |node|
          yield node
        end
      end

      def twilio_loop(twilio_options, options = {})
        infinite_loop = options.delete(:finite) ? INFINITY.times : loop
        twilio_options["loop"].to_s == "0" ? infinite_loop : (twilio_options["loop"] || 1).to_i.times
      end

      def twilio_options(node)
        options = {}
        node.attributes.each do |key, attribute|
          options[key] = attribute.value
        end
        options
      end

      def normalized_from
        return_value = normalized_destination(call.from)
        unless destination_valid?(return_value)
          normalized_p_asserted_identity = normalized_destination(
            call.variables["variable_sip_p_asserted_identity"]
          )
          return_value = normalized_p_asserted_identity if destination_valid?(normalized_p_asserted_identity)
        end
        return_value
      end

      def normalized_to
        normalized_destination(call.to)
      end

      def api_version
        "adhearsion-twilio-#{Adhearsion::Twilio::VERSION}"
      end

      def normalized_destination(raw_destination)
        # remove port if and scheme if given
        destination = raw_destination.gsub(/(\d+)\:\d+/, '\1').gsub(/^[a-z]+\:/, "") if raw_destination
        destination = Mail::Address.new(destination).local
        destination_valid?(destination) ? "+#{destination.gsub('+', '')}" : destination
      end

      def destination_valid?(raw_destination)
        raw_destination =~ /\A\+?\d+\z/
      end

      def config
        Adhearsion.config[:twilio]
      end

      def voice_request_url
        metadata[:voice_request_url] || config.voice_request_url
      end

      def voice_request_method
        metadata[:voice_request_method] || config.voice_request_method.presence || "post"
      end

      def status_callback_url
        metadata[:status_callback_url] || config.status_callback_url
      end

      def status_callback_method
        metadata[:status_callback_method] || config.status_callback_method.presence || "post"
      end

      def auth_token
        config.auth_token || DEFAULT_AUTH_TOKEN
      end

      def extract_auth_from_url(url)
        basic_auth = {}
        uri = URI.parse(url)

        if uri.user
          basic_auth[:username] = uri.user
          basic_auth[:password] = uri.password
        end

        uri.user = nil
        uri.password = nil

        [basic_auth, uri.to_s]
      end

      def not_yet_supported!
        raise ArgumentError, "Not yet supported"
      end
    end
  end
end
