# frozen_string_literal: true

require_relative "../../model"

class GithubApp < Sequel::Model
  many_to_one :project
  one_to_many :installations, class: :GithubInstallation, read_only: true

  plugin ResourceMethods, encrypted_columns: [:client_secret, :private_key, :webhook_secret]

  def github?
    host == "github.com"
  end

  def ghe?
    host.end_with?(".ghe.com")
  end

  def api_endpoint
    if github?
      "https://api.github.com/"
    elsif ghe?
      "https://api.#{host}/"
    else
      "https://#{host}/api/v3/"
    end
  end

  def web_endpoint
    "https://#{host}/"
  end

  # GHE.com tenants use the github.com URL scheme for app pages, while
  # GitHub Enterprise Server serves them under /github-apps.
  def app_path
    (github? || ghe?) ? "apps" : "github-apps"
  end

  def installation_new_url
    "#{web_endpoint}#{app_path}/#{slug}/installations/new"
  end

  def installation_settings_url(installation_id)
    "#{web_endpoint}#{app_path}/#{slug}/installations/#{installation_id}"
  end

  def usable_by_project?(project)
    project_id.nil? || project_id == project.id
  end
end

# Table: github_app
# Columns:
#  id             | uuid                     | PRIMARY KEY DEFAULT gen_random_ubid_uuid(522)
#  host           | text                     | NOT NULL
#  slug           | text                     | NOT NULL
#  app_id         | bigint                   | NOT NULL
#  client_id      | text                     | NOT NULL
#  client_secret  | text                     | NOT NULL
#  private_key    | text                     | NOT NULL
#  webhook_secret | text                     | NOT NULL
#  project_id     | uuid                     |
#  created_at     | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  github_app_pkey     | PRIMARY KEY btree (id)
#  github_app_host_key | UNIQUE btree (host)
# Foreign key constraints:
#  github_app_project_id_fkey | (project_id) REFERENCES project(id)
# Referenced By:
#  github_installation | github_installation_github_app_id_fkey | (github_app_id) REFERENCES github_app(id)
