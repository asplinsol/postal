module Postal
  module MessageDB
    class Delivery

      def self.create(message, attributes = {})
        attributes = message.database.stringify_keys(attributes)
        attributes = attributes.merge("message_id" => message.id, "timestamp" => Time.now.to_f)
        id = message.database.insert("deliveries", attributes)
        delivery = Delivery.new(message, attributes.merge("id" => id))
        delivery.update_statistics
        delivery.send_webhooks
        delivery
      end

      def initialize(message, attributes)
        @message = message
        @attributes = attributes.stringify_keys
      end

      def method_missing(name, value = nil, &block)
        return unless @attributes.has_key?(name.to_s)

        @attributes[name.to_s]
      end

      def timestamp
        @timestamp ||= @attributes["timestamp"] ? Time.zone.at(@attributes["timestamp"]) : nil
      end

      def update_statistics
        if status == "Held"
          @message.database.statistics.increment_all(timestamp, "held")
        end

        return unless status == "Bounced" || status == "HardFail"

        @message.database.statistics.increment_all(timestamp, "bounces")
      end

      def send_webhooks
        return unless webhook_event

        WebhookRequest.trigger(@message.database.server_id, webhook_event, webhook_hash)
      end

      def webhook_hash
        {
          :message => @message.webhook_hash,
          :status => self.status,
          :details => self.details,
          :output => self.output.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').scrub,
          :sent_with_ssl => self.sent_with_ssl,
          :timestamp => @attributes['timestamp'],
          :time => self.time
        }
      end

      def webhook_event
        @webhook_event ||= case status
                           when "Sent" then "MessageSent"
                           when "SoftFail" then "MessageDelayed"
                           when "HardFail" then "MessageDeliveryFailed"
                           when "Held" then "MessageHeld"
                           end
      end

    end
  end
end
