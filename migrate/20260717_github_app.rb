# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_app) do
      # UBID.to_base32_n("ga") => 522
      column :id, :uuid, primary_key: true, default: Sequel.lit("gen_random_ubid_uuid(522)")
      column :host, :text, null: false
      column :slug, :text, null: false
      column :app_id, :bigint, null: false
      column :client_id, :text, null: false
      column :client_secret, :text, null: false
      column :private_key, :text, null: false
      column :webhook_secret, :text, null: false
      foreign_key :project_id, :project, type: :uuid
      column :created_at, :timestamptz, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique [:host]
    end

    alter_table(:github_installation) do
      add_foreign_key :github_app_id, :github_app, type: :uuid
    end
  end
end
