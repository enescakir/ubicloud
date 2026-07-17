# frozen_string_literal: true

require "octokit"
require "jwt"
require "yaml"

Octokit.configure do |c|
  c.connection_options = {
    request: {
      open_timeout: 5,
      timeout: 5,
    },
  }
end

module Github
  MINUTE_BILLING_RATE_IDS = BillingRate.from_resource_type("GitHubRunnerMinutes").map { it["id"] }.freeze

  # The app argument is a GithubApp record for apps registered on GitHub
  # Enterprise instances. A nil app means our public app on github.com,
  # whose credentials come from Config.
  def self.oauth_client(app = nil)
    options = if app
      {client_id: app.client_id, client_secret: app.client_secret, api_endpoint: app.api_endpoint, web_endpoint: app.web_endpoint}
    else
      {client_id: Config.github_app_client_id, client_secret: Config.github_app_client_secret}
    end
    Octokit::Client.new(**options)
  end

  def self.app_client(app = nil)
    current = Time.now.to_i
    private_key = OpenSSL::PKey::RSA.new(app&.private_key || Config.github_app_private_key)
    key = {
      iat: current,
      exp: current + (8 * 60),
      iss: app&.app_id || Config.github_app_id,
    }
    bearer_token = JWT.encode(key, private_key, "RS256")

    options = {bearer_token:, per_page: 100}
    options[:api_endpoint] = app.api_endpoint if app
    Octokit::Client.new(**options)
  end

  def self.installation_client(installation_id, app: nil, auto_paginate: false, per_page: 100)
    access_token = app_client(app).create_app_installation_access_token(installation_id)[:token]
    options = {access_token:, auto_paginate:, per_page:}
    options[:api_endpoint] = app.api_endpoint if app
    Octokit::Client.new(**options)
  end

  # :nocov:
  def self.freeze
    runner_labels
    super
  end
  # :nocov:

  def self.runner_labels
    @runner_labels ||= begin
      labels = YAML.load_file("config/github_runner_labels.yml").to_h { [it["name"], it] }
      labels.transform_values do |v|
        new = (a = v["alias_for"]) ? labels[a] : v
        new["vm_size"] = "#{new["family"]}-#{new["vcpus"]}"
        Validation.validate_vm_size(new["vm_size"], new["arch"])
        new
      end.freeze
    end
  end
end
