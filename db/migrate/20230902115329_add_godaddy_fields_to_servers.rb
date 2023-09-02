class AddGodaddyFieldsToServers < ActiveRecord::Migration[6.1]
  def change
    add_column :servers, :godaddy_key, :string
    add_column :servers, :godaddy_secret, :string
  end
end
