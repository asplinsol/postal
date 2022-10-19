# == Schema Information
#
# Table name: routes
#
#  id            :integer          not null, primary key
#  uuid          :string(255)
#  server_id     :integer
#  domain_id     :integer
#  endpoint_id   :integer
#  endpoint_type :string(255)
#  name          :string(255)
#  spam_mode     :string(255)
#  created_at    :datetime
#  updated_at    :datetime
#  token         :string(255)
#  mode          :string(255)
#
# Indexes
#
#  index_routes_on_token  (token)
#

class Route < ApplicationRecord

  MODES = ['Endpoint', 'Accept', 'Hold', 'Bounce', 'Reject']
  
  include HasUUID

  belongs_to :server
  belongs_to :domain, optional: true
  belongs_to :endpoint, polymorphic: true, optional: true
  has_many :additional_route_endpoints, dependent: :destroy

  SPAM_MODES = ['Mark', 'Quarantine', 'Fail']
  ENDPOINT_TYPES = ['SMTPEndpoint', 'HTTPEndpoint', 'AddressEndpoint']
  IGNORE_SUBJECTS = ["wuI", "wrmpbx", "Undeliverable", "Delivery Status Notification (Failure)", "Delivery Status Notification (Delay)", "Mail delivery failed", "Automatic Reply", "Out of office", "couldn't be delivered", "permanent fatal errors", "Delivery Failure", "Delivery has failed", "Undelivered Mail", "Mail Delivery Failure", "Unzustellbar", "Respuesta automática", "Entrega retrasada", "Automatisch antwoord", "Auto Svar", "Delivery delayed", "communication failure", "Postmaster", "Kan ikke leveres", "Nelivrabil", "Your Google Account is disabled", "Kézbesíthetetlen", "Olevererbart", "New device signed in to", "attempt was blocked", "permanent error", "Security alert", "Delivery Failed", "Returned mail", "Email Delivery Failure", "Mail Delivery", "could not be delivered", "Automaattinen vastaus", "Automatisk sva", "Autosvar", "Jag är på semester", "wasn’t delivered", "fuori dall'ufficio", "assente dall'ufficio", "Risposta automatica", "Réponse automatique", "Non recapitabile", "Échec de la remise", "Zerospam", "Automatikus válasz", "Abwesenheitsnotiz", "Automatische Antwort", "This e-mail account doesn't exist", "Out of the office"]
  validates :name, :presence => true, :format => /\A(([a-z0-9\-\.]*)|(\*)|(__returnpath__))\z/
  validates :spam_mode, :inclusion => {:in => SPAM_MODES}
  validates :endpoint, :presence => {:if => proc { self.mode == 'Endpoint' }}
  validates :domain_id, :presence => {:unless => :return_path?}
  validate :validate_route_is_routed
  validate :validate_domain_belongs_to_server
  validate :validate_endpoint_belongs_to_server
  validate :validate_name_uniqueness
  validate :validate_return_path_route_endpoints
  validate :validate_no_additional_routes_on_non_endpoint_route

  after_save :save_additional_route_endpoints

  random_string :token, type: :chars, length: 8, unique: true

  def return_path?
    name == "__returnpath__"
  end

  def description
    if return_path?
      "Return Path"
    else
      "#{name}@#{domain.name}"
    end
  end

  def _endpoint
    if mode == "Endpoint"
      @endpoint ||= endpoint ? "#{endpoint.class}##{endpoint.uuid}" : nil
    else
      @endpoint ||= mode
    end
  end

  def _endpoint=(value)
    if value.blank?
      self.endpoint = nil
      self.mode = nil
    elsif value =~ /\#/
      class_name, id = value.split("#", 2)
      unless ENDPOINT_TYPES.include?(class_name)
        raise Postal::Error, "Invalid endpoint class name '#{class_name}'"
      end

      self.endpoint = class_name.constantize.find_by_uuid(id)
      self.mode = "Endpoint"
    else
      self.endpoint = nil
      self.mode = value
    end
  end

  def forward_address
    @forward_address ||= "#{token}@#{Postal.config.dns.route_domain}"
  end

  def wildcard?
    name == "*"
  end

  def additional_route_endpoints_array
    @additional_route_endpoints_array ||= additional_route_endpoints.map(&:_endpoint)
  end

  def additional_route_endpoints_array=(array)
    @additional_route_endpoints_array = array.reject(&:blank?)
  end

  def save_additional_route_endpoints
    return unless @additional_route_endpoints_array

    seen = []
    @additional_route_endpoints_array.each do |item|
      if existing = additional_route_endpoints.find_by_endpoint(item)
        seen << existing.id
      else
        route = additional_route_endpoints.build(_endpoint: item)
        if route.save
          seen << route.id
        else
          route.errors.each do |field, message|
            errors.add :base, message
          end
          raise ActiveRecord::RecordInvalid
        end
      end
    end
    additional_route_endpoints.where.not(id: seen).destroy_all
  end

  #
  # This message will create a suitable number of message objects for messages that
  #  are destined for this route. It receives a block which can set the message content
  # but most information is specified already.
  #
  # Returns an array of created messages.
  #
  def create_messages(&block)
    messages = []
    message = build_message
    if mode == "Endpoint" && server.message_db.schema_version >= 18
      message.endpoint_type = endpoint_type
      message.endpoint_id = endpoint_id
    end
    block.call(message)
    message.save
    messages << message

    if IGNORE_SUBJECTS.any? { |s| message.subject.include? s }
      
    else
      # Also create any messages for additional endpoints that might exist
      if self.mode == 'Endpoint' && self.server.message_db.schema_version >= 18
        self.additional_route_endpoints.each do |endpoint|
          next unless endpoint.endpoint
          message = self.build_message
          message.endpoint_id = endpoint.endpoint_id
          message.endpoint_type = endpoint.endpoint_type
          block.call(message)
          message.save
          messages << message
        end
      end
    end

    messages
  end

  def build_message
    message = server.message_db.new_message
    message.scope = "incoming"
    message.rcpt_to = description
    message.domain_id = domain&.id
    message.route_id = id
    message
  end

  private

  def validate_route_is_routed
    return unless mode.nil?

    errors.add :endpoint, "must be chosen"
  end

  def validate_domain_belongs_to_server
    if domain && ![server, server.organization].include?(domain.owner)
      errors.add :domain, :invalid
    end

    return unless domain && !domain.verified?

    errors.add :domain, "has not been verified yet"
  end

  def validate_endpoint_belongs_to_server
    return unless endpoint && endpoint&.server != server

    errors.add :endpoint, :invalid
  end

  def validate_name_uniqueness
    return if server.nil?

    if domain
      if route = Route.includes(:domain).where(domains: { name: domain.name }, name: name).where.not(id: id).first
        errors.add :name, "is configured on the #{route.server.full_permalink} mail server"
      end
    elsif route = Route.where(name: "__returnpath__").where.not(id: id).exists?
      errors.add :base, "A return path route already exists for this server"
    end
  end

  def validate_return_path_route_endpoints
    return unless return_path?
    return unless mode != "Endpoint" || endpoint_type != "HTTPEndpoint"

    errors.add :base, "Return path routes must point to an HTTP endpoint"
  end

  def validate_no_additional_routes_on_non_endpoint_route
    return unless mode != "Endpoint" && !additional_route_endpoints_array.empty?

    errors.add :base, "Additional routes are not permitted unless the primary route is an actual endpoint"
  end

  def self.find_by_name_and_domain(name, domain)
    route = Route.includes(:domain).where(name: name, domains: { name: domain }).first
    if route.nil?
      route = Route.includes(:domain).where(name: "*", domains: { name: domain }).first
    end
    route
  end

end
