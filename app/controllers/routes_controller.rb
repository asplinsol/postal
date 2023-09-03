class RoutesController < ApplicationController

  include WithinOrganization

  before_action { @server = organization.servers.present.find_by_permalink!(params[:server_id]) }
  before_action { params[:id] && @route = @server.routes.find_by_uuid!(params[:id]) }

  def index
    @routes = @server.routes.order(:name).includes(:domain, :endpoint).to_a
  end

  def new
    @route = @server.routes.build
  end

  def create
    @route = @server.routes.build(safe_params)
    if @route.save
      redirect_to_with_json [organization, @server, :routes]
    else
      render_form_errors "new", @route
    end
  end

  def update
    if @route.update(safe_params)
      redirect_to_with_json [organization, @server, :routes]
    else
      render_form_errors "edit", @route
    end
  end

  def destroy
    @route.destroy
    redirect_to_with_json [organization, @server, :routes]
  end

  def import
    if params[:file].present?
      csv_text = File.read(params[:file].path)
      csv = CSV.parse(csv_text, headers: true)
      success_count = 0
      error_count = 0

      # Fetch the first HTTP endpoint from @server
      http_endpoint = @server.http_endpoints.first

      if http_endpoint.nil?
        redirect_to_with_json [organization, @server, :routes], alert: 'No HTTP endpoint found.'
        return
      end

      csv.each do |row|
        email_address = row['email address']
        unless email_address.include?('@')
          Rails.logger.error("Skipping invalid email address: #{email_address}")
          next
        end

        domain_name = email_address.split('@').last # Extract the domain part from the email address
        domain = Domain.find_by(name: domain_name) # Find the corresponding domain

        if domain
          route_hash = {
            'name' => email_address.split('@').first,
            'domain_id' => domain.id,
            'spam_mode' => 'Mark',
            'server_id' => @server.id,  # Assuming @server is set in your before_action
            :_endpoint => "HTTPEndpoint##{http_endpoint.uuid}" # Using the first HTTP endpoint's UUID
          }

          additional_route_endpoints_array = []

          # Custom logic to handle forwarding (adjust as needed)
          forward_to_address = row['Forward to']
          if forward_to_address.present? && forward_to_address.include?('@')
            # Find the AddressEndpoint where the name matches forward_to_address
            address_endpoint = @server.address_endpoints.find_by(address: forward_to_address)
            if address_endpoint
              additional_route_endpoints_array << "AddressEndpoint##{address_endpoint.uuid}"
            else
              Rails.logger.error("Failed to find AddressEndpoint for name: #{forward_to_address}")
            end
          end

          route_hash[:additional_route_endpoints_array] = additional_route_endpoints_array

          route = @server.routes.build(route_hash)

          if route.save
            success_count += 1
          else
            # Log or handle the errors here
            error_count += 1
            Rails.logger.error("Failed to import route: #{route.inspect}")
          end
        else
          error_count += 1
          Rails.logger.error("Failed to find domain for email address: #{email_address}")
        end
      end

      if success_count > 0
        flash[:notice] = "#{success_count} routes imported successfully."
      end

      if error_count > 0
        flash[:alert] = "#{error_count} routes failed to import."
      end

      redirect_to_with_json [organization, @server, :routes]
    else
      redirect_to_with_json [organization, @server, :routes], alert: 'Please upload a CSV file'
    end
  end


  private

  def safe_params
    params.require(:route).permit(:name, :domain_id, :spam_mode, :_endpoint, additional_route_endpoints_array: [])
  end

end
