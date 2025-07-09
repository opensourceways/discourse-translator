# frozen_string_literal: true

require 'connection_pool'
require 'json'

module DiscourseTranslator
  module Provider
    class Huaweicloud < BaseProvider
      # 常量定义
      TRANSLATE_URI = "https://nlp-ext.:project_name.myhuaweicloud.com/v1/:project_id/machine-translation/text-translation".freeze
      DETECT_URI = "https://nlp-ext.:project_name.myhuaweicloud.com/v1/:project_id/machine-translation/language-detection".freeze
      ISSUE_TOKEN_URI = "https://iam.:project_name.myhuaweicloud.com/v3/auth/tokens".freeze
      LENGTH_LIMIT = 2000

      LANG_SUPPORT_ERROR = 999
      TRANSLATE_API_ERROR = 777

      SUPPORTED_LANG_MAPPING = {
        ar: 'ar',
        de: 'de',
        ru: 'ru',
        fr: 'fr',
        ko: 'ko',
        pt: 'pt',
        ja: 'ja',
        th: 'th',
        tr: 'tr',
        es: 'es',
        en: 'en',
        en_GB: 'en',
        en_US: 'en',
        vi: 'vi',
        zh_CN: 'zh',
        zh_TW: 'zh',
        zh: "zh",
      }.freeze

      CONNECTION_POOL = ConnectionPool.new(size: 3, timeout: 5) do
        Faraday.new do |conn|
          conn.adapter FinalDestination::FaradayAdapter
          conn.options.timeout = 10
          conn.request :retry, {
            max: 2,
            interval: 0.5,
            exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
          }
        end
      end

      def self.access_token
        existing_token = Discourse.redis.get(cache_key)
        if existing_token
          Rails.logger.info("Huaweicloud: Using cached access token")
          return existing_token
        end

        CONNECTION_POOL.with do |connection|
          url = ISSUE_TOKEN_URI.dup.sub(':project_name', SiteSetting.translator_huaweicloud_project_name)
          
          body = {
            auth: {
              identity: {
                methods: ["password"],
                password: {
                  user: {
                    domain: { name: ENV["SENSITIVE_DOMAIN_NAME"] },
                    name: ENV["SENSITIVE_NAME"],
                    password: ENV["SENSITIVE_PASSWORD"]
                  }
                }
              },
              scope: {
                project: {
                  id: SiteSetting.translator_huaweicloud_project_id,
                  name: SiteSetting.translator_huaweicloud_project_name
                }
              }
            }
          }.to_json
          
          begin
            response = connection.post(
              url,
              body,
              'Content-Type' => 'application/json;charset=utf8'
            )

            if response.status == 201 && response.headers['x-subject-token']
              token = response.headers['x-subject-token']
              Discourse.redis.setex(cache_key, 23.hours.to_i, token)
              token
            else
              Rails.logger.error("Huaweicloud: Failed to obtain access token. Status: #{response.status}, Body: #{response.body}")
              handle_token_error(response)
            end
          rescue => e
            Rails.logger.error("Huaweicloud: Exception while requesting access token: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
            raise
          end
        end
      end

      def self.detect!(topic_or_post)
        url = DETECT_URI.dup
          .sub(':project_name', SiteSetting.translator_huaweicloud_project_name)
          .sub(':project_id', SiteSetting.translator_huaweicloud_project_id)

        text = text_for_detection(topic_or_post).truncate(LENGTH_LIMIT, omission: nil)

        res = result(
          url,
          :post,
          { 
            'X-Auth-Token' => access_token,
            'Content-Type' => 'application/json;charset=utf8' 
          },
          { text: text }
        )
        
        if res == TRANSLATE_API_ERROR || res.nil?
          Rails.logger.error("Huaweicloud: Language detection failed")
          nil
        else
          Rails.logger.info("Huaweicloud: Detected language: #{res['detected_language']}")
          res['detected_language']
        end
      end

      def self.translate_post!(post, target_locale_sym = I18n.locale, opts = {})
        raw = opts.key?(:raw) ? opts[:raw] : !opts[:cooked]
        text = text_for_translation(post, raw: raw)

        begin
          if raw
            translate_text!(text, target_locale_sym)
          else
            parsed_html = Nokogiri::HTML(text)
            
            traverse_result = traverse(parsed_html, target_locale_sym)
            if traverse_result
              result = parsed_html.inner_html
              result
            else
              raise TranslatorError.new(I18n.t("translator.huaweicloud.fail"))
            end
          end
        rescue => e
          Rails.logger.error("Huaweicloud: Exception in translate_post!: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
          raise
        end
      end

      def self.translate_topic!(topic, target_locale_sym = I18n.locale)
        text = text_for_translation(topic)
        translate_text!(text, target_locale_sym)
      end

      def self.translate_text!(text, target_locale_sym = I18n.locale)
        detected_lang = detect_text(text)
        
        target_lang = SUPPORTED_LANG_MAPPING[target_locale_sym]

        url = TRANSLATE_URI.dup
          .sub(':project_name', SiteSetting.translator_huaweicloud_project_name)
          .sub(':project_id', SiteSetting.translator_huaweicloud_project_id)

        res = result(
          url,
          :post,
          { 
            'X-Auth-Token' => access_token,
            'Content-Type' => 'application/json;charset=utf8' 
          },
          {
            text: text,
            from: detected_lang,
            to: target_lang
          }
        )
      
        case res
        when Hash
          res["translated_text"]
        when LANG_SUPPORT_ERROR
          LANG_SUPPORT_ERROR
        when TRANSLATE_API_ERROR
          TRANSLATE_API_ERROR
        else
          nil
        end
      end

      def self.translate_supported?(source_lang, target_lang)
        return false unless source_lang && target_lang
        
        source_supported = SUPPORTED_LANG_MAPPING.key?(source_lang.to_sym)
        target_code = SUPPORTED_LANG_MAPPING[target_lang.to_sym] || 
                     target_lang.to_s.split('_').first
        target_supported = SUPPORTED_LANG_MAPPING.value?(target_code)
        
        source_supported && target_supported
      end

      private

      def self.access_token_key
        "huaweicloud-translator"
      end

      def self.traverse(html, target_locale_sym)
        text_nodes = html.css('text').select { |n| n.content.present? && n.content != "\n" }
        text_nodes = []
        html.traverse do |node|
          if node.text? && node.content.present? && node.content.strip != ""
            text_nodes << node
          end
        end

        return nil if text_nodes.empty?

        translation_requests = prepare_translation_requests(text_nodes)

        translated_texts = process_translation_requests(translation_requests, target_locale_sym)

        translated_texts = retract_out_char(translated_texts)

        replacement = parse_result(translated_texts)
        
        if translated_texts && text_nodes.size == replacement.size
          i = 0
          html.traverse do |node|
            if node.name == 'text' && !node.content.blank? && node.content != "\n"
              node.content = replacement[i]
              i = i + 1
            end
          end
          html
        else
          Rails.logger.error("Huaweicloud: Translation failed - nodes: #{text_nodes.size}, results: #{translated_texts&.size || 'nil'}")
          nil
        end
      rescue => e
        Rails.logger.error("Huaweicloud: Exception in traverse: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
        nil
      end

      def self.detect_text(text)
        url = DETECT_URI.dup
          .sub(':project_name', SiteSetting.translator_huaweicloud_project_name)
          .sub(':project_id', SiteSetting.translator_huaweicloud_project_id)

        res = result(
          url,
          :post,
          { 
            'X-Auth-Token' => access_token,
            'Content-Type' => 'application/json;charset=utf8' 
          },
          { text: text.truncate(LENGTH_LIMIT, omission: nil) }
        )

        res == TRANSLATE_API_ERROR || res.nil? ? nil : res['detected_language']
      end

      def self.prepare_translation_requests(text_nodes)
        requests = []
        current_request = ""

        #使用标签包含每个翻译节点
        text_nodes.each do |node|
          content = node.content.gsub("\n", "<br>")
          wrapped_content = "<p>#{content} </p>\n"

          if (current_request + wrapped_content).bytesize > LENGTH_LIMIT
            requests << current_request unless current_request.empty?
            current_request = wrapped_content
          else
            current_request += wrapped_content
          end
        end

        requests << current_request unless current_request.empty?
        requests
      end

      def self.process_translation_requests(requests, target_locale_sym)
        
        requests.map.with_index do |request, i|
          response = translate_text!(request, target_locale_sym)
      
          case response
          when Hash
            response["translated_text"] || request
          when String
            response
          when LANG_SUPPORT_ERROR
            Rails.logger.warn("Huaweicloud: Unsupported language in request #{i+1}, using original text")
            request
          else
            Rails.logger.error("Huaweicloud: Failed to translate request #{i+1}")
            request
          end
        end
      rescue => e
        Rails.logger.error("Huaweicloud: Exception in process_translation_requests: #{e.class} - #{e.message}")
        requests
      end

      def self.retract_out_char(input)
        str = input.is_a?(Array) ? input.join("\n") : input.to_s
        
        return "" if str.empty?
      
        paras = str.split("\n").map do |para|
          para = para.gsub("<p>", '')
          para = para.reverse.gsub(">p/<", '').reverse
          para.gsub("<br>", "\n")
        end
      
        paras.map { |para| "<p>#{para}</p>\n" }.join
      end

      def self.parse_result(str)
        parsed_res = Nokogiri::HTML(str)
        ans = []
        parsed_res.traverse do |node|
          if node.name == 'p' && !node.content.blank? && node.content != "\n"
            ans << node.content
          end
        end
        ans
      end

      def self.apply_translations(text_nodes, translated_texts)
        text_nodes.each_with_index do |node, i|
          node.content = translated_texts[i] if translated_texts[i]
        end
      end

      def self.handle_token_error(response)
        if response.body.blank?
          error_msg = "Huaweicloud: Missing token in response"
          Rails.logger.error(error_msg)
          raise TranslatorError.new(I18n.t("translator.huaweicloud.missing_token"))
        else
          error = JSON.parse(response.body)["error"] rescue {}
          error_message = "#{error['code'] || 'unknown'}: #{error['message'] || 'unknown error'}"
          Rails.logger.error("Huaweicloud: Token error - #{error_message}")
          raise TranslatorError.new(error_message)
        end
      end

      def self.result(url, method, headers, body)
        CONNECTION_POOL.with do |connection|
          begin
            response = connection.run_request(
              method,
              url,
              body.to_json,
              headers
            )

            parsed_body = JSON.parse(response.body) rescue nil

            if response.status != 200
              Rails.logger.error("Huaweicloud: API returned error status: #{response.status}")
              if parsed_body && "Language or Scene is not supported. ".in?(parsed_body["error_msg"])
                LANG_SUPPORT_ERROR
              else
                TRANSLATE_API_ERROR
              end
            else
              parsed_body
            end
          rescue => e
            Rails.logger.error("Huaweicloud: Exception in API request: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
            TRANSLATE_API_ERROR
          end
        end
      end

      def self.cache_key
        "#{access_token_key}-#{SiteSetting.translator_huaweicloud_project_id}"
      end
    end
  end
end