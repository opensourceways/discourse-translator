# frozen_string_literal: true

require_relative 'base'
require 'json'

module DiscourseTranslator
    class Huawei < Base
      TRANSLATE_URI = "https://nlp-ext.:project_name.myhuaweicloud.com/v1/:project_id/machine-translation/text-translation".freeze
      DETECT_URI = "https://nlp-ext.:project_name.myhuaweicloud.com/v1/:project_id/machine-translation/language-detection".freeze
      ISSUE_TOKEN_URI = "https://iam.:project_name.myhuaweicloud.com/v3/auth/tokens".freeze
    
      LENGTH_LIMIT = 2000

    # Hash which maps Discourse's locale code to Huawei Translate's locale code found in
    # https://support.huaweicloud.com/api-nlp/nlp_03_0024.html
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
        }
    
      def self.access_token_key
        "huawei-translator"
      end
  
      def self.access_token
        existing_token = Discourse.redis.get(cache_key)
  
        if existing_token
          existing_token
        else
          connection = Faraday.new do |f| 
              f.adapter FinalDestination::FaradayAdapter
          end
          url = "#{DiscourseTranslator::Huawei::ISSUE_TOKEN_URI}".sub(':project_name', SiteSetting.translator_huawei_project_name)
          method = "POST".downcase.to_sym
          body = { 
                auth: { 
                    identity: {
                        methods: ["password"],
                        password: {
                            user: {
                                domain: {
                                    name: ENV["SENSITIVE_DOMAIN_NAME"]
                                },
                                name: ENV["SENSITIVE_NAME"],
                                password: ENV["SENSITIVE_PASSWORD"]
                            }
                        }
                    }, 
                    scope: {
                        project: {
                            id: SiteSetting.translator_huawei_project_id,
                            name: SiteSetting.translator_huawei_project_name
                        }
                    }
                }
            }.to_json
          body = JSON.parse(body).to_s.gsub('=>', ':')
          headers = { 'Content-Type' => 'application/json;charset=utf8' }
          response = connection.run_request(method, url, body, headers)
  
          if response.status == 201 && (response_body = response.headers).present?
            Discourse.redis.setex(cache_key, 24.hours.to_i, response_body['x-subject-token'])
            response_body['x-subject-token']
          elsif response.body.blank?
            raise TranslatorError.new(I18n.t("translator.huawei.missing_token"))
          else
            # The possible response isn't well documented in Huawei's API so
            # it might break from time to time.
            error = JSON.parse(response.body)["error"]
            raise TranslatorError.new("#{error['code']}: #{error['message']}")
          end
        end
      end

      def self.detect(post)
        post.custom_fields[DiscourseTranslator::DETECTED_LANG_CUSTOM_FIELD] ||= begin
          res = result("#{DETECT_URI}".sub(':project_name', SiteSetting.translator_huawei_project_name).sub(':project_id', SiteSetting.translator_huawei_project_id),
                "POST".downcase.to_sym,
                { 'X-Auth-Token' => access_token, 'Content-Type' => 'application/json;charset=utf8' },
                {
                text: post.raw.truncate(LENGTH_LIMIT, omission: nil)
                }
                )
          if res == 777
            return
          else
            res['detected_language']
          end
        end
      end
    
      def self.translate(post)
        detected_lang = detect(post)

        if detected_lang.nil?
          raise TranslatorError.new(I18n.t("translator.huawei.fail_1"))
        end

        if !SUPPORTED_LANG_MAPPING.keys.include?(detected_lang.to_sym) &&
          !SUPPORTED_LANG_MAPPING.values.include?(detected_lang.to_s)
          raise TranslatorError.new(I18n.t("translator.failed"))
        end

        translated_text = from_custom_fields(post) do
          parsed_html = Nokogiri::HTML(post.cooked)
          translated_html = traverse(parsed_html, detected_lang)
          if translated_html
            translated_html.inner_html
          else
            raise TranslatorError.new(I18n.t("translator.huawei.fail_2"))
          end
        end
        
        log("original text: #{post.cooked}")
        log("translated text: #{translated_text}")
        [detected_lang, translated_text]
      end

      def self.traverse(html, detected_lang)
        text_node = []
        html.traverse do |node|
          if node.name == 'text' and !node.content.blank? and node.content != "\n"
            text_node << node
          end
        end
        log("text_node_num: #{text_node.size}")

        translate_strs = []
        translate_str = ""
        pre_str = "<p>"
        post_str = "</p>\n"
        text_node.each do |n|
          tmp = translate_str + pre_str + n.content.gsub("\n", "<br>") + post_str
          if tmp.length > LENGTH_LIMIT   
            translate_strs << translate_str
            translate_str = pre_str + n.content.gsub("\n", "<br>") + post_str
          else
            translate_str = tmp
          end
        end
        translate_strs << translate_str if !translate_str.blank?
        log("request_num: #{translate_strs.size}")

        translate_str_all = ""
        translate_strs.each do |str|
          translate_str_all = translate_str_all + str
        end
        log("origin_str: #{translate_str_all}")

        translated_strs = []
        translate_strs.each do |str|
          res = request_translation(str, detected_lang)
          if res == 999
            translated_strs << str
          elsif res != 777
            translated_strs << res
          else
            return
          end
        end

        translated_str_all = ""
        translated_strs.each do |str|
          translated_str_all = translated_str_all + str
        end
        log("translated_str: #{translated_str_all}")
        translated_str_all = retract_out_char(translated_str_all)
        log("postprocessed_translated_str: #{translated_str_all}")
        replacement = parse_result(translated_str_all)
        log("replacement_num: #{replacement.size}")

        if text_node.size != replacement.size
          log("num: #{text_node.size} #{replacement.size}")
          return
        end

        i = 0
        html.traverse do |node|
          if node.name == 'text' and !node.content.blank? and node.content != "\n"
            node.content = replacement[i]
            i = i + 1
          end
        end
        html
      end

      def self.parse_result(str)
        parsed_res = Nokogiri::HTML(str)
        ans = []
        parsed_res.traverse do |node|
          if node.name == 'p' and !node.content.blank? and node.content != "\n"
            ans << node.content
          end
        end
        ans
      end

      def self.retract_out_char(str)
        paras = str.split("\n")
        for para in paras do
          para.sub!("<p>", '')
          para.reverse!
          para.sub!(">p/<", '')
          para.reverse!
        end

        ans = ""
        for para in paras do
          ans = ans + "<p>" + para.gsub("<br>", "\n") + "</p>\n"
        end
        ans
      end

      def self.request_translation(text, detected_lang)
        res = result("#{TRANSLATE_URI}".sub(':project_name', SiteSetting.translator_huawei_project_name).sub(':project_id', SiteSetting.translator_huawei_project_id),
                "POST".downcase.to_sym,
                { 'X-Auth-Token' => access_token, 'Content-Type' => 'application/json;charset=utf8' },
                {
                text: text,
                from: detected_lang,
                to: SUPPORTED_LANG_MAPPING[I18n.locale]
                }
                )
        if res != 999 or res != 777
          res["translated_text"]
        else
          res
        end
      end

      def self.result(url, method, headers, body)
        connection = Faraday.new do |f| 
            f.adapter FinalDestination::FaradayAdapter
        end

        body = JSON.parse body.to_json
        response = connection.run_request(method, url, body.to_s.gsub('=>', ':'), headers)
  
        body = nil
        begin
          body = JSON.parse(response.body)
        rescue JSON::ParserError
        end
  
        if response.status != 200
          log("res: #{response.body}")
          if "Language or Scene is not supported. ".in? body["error_msg"]
            999
          elsif
            777
          end
        else
          body
        end
      end

      def self.log(info)
        Rails.logger.warn("Translator Debugging: #{info}") if SiteSetting.translator_debug_info
      end
    end
end
