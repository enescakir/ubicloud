# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubApp do
  def create_app(host)
    described_class.create(host:, slug: "ubicloud-app", app_id: 1234, client_id: "client-id", client_secret: "client-secret", private_key: "private-key", webhook_secret: "webhook-secret")
  end

  it "derives endpoints and URLs for github.com" do
    app = create_app("github.com")
    expect(app.api_endpoint).to eq("https://api.github.com/")
    expect(app.web_endpoint).to eq("https://github.com/")
    expect(app.installation_new_url).to eq("https://github.com/apps/ubicloud-app/installations/new")
    expect(app.installation_settings_url(567)).to eq("https://github.com/apps/ubicloud-app/installations/567")
  end

  it "derives endpoints and URLs for GHE.com tenants" do
    app = create_app("acme.ghe.com")
    expect(app.api_endpoint).to eq("https://api.acme.ghe.com/")
    expect(app.web_endpoint).to eq("https://acme.ghe.com/")
    expect(app.installation_new_url).to eq("https://acme.ghe.com/apps/ubicloud-app/installations/new")
    expect(app.installation_settings_url(567)).to eq("https://acme.ghe.com/apps/ubicloud-app/installations/567")
  end

  it "derives endpoints and URLs for GitHub Enterprise Server" do
    app = create_app("github.acme.com")
    expect(app.api_endpoint).to eq("https://github.acme.com/api/v3/")
    expect(app.web_endpoint).to eq("https://github.acme.com/")
    expect(app.installation_new_url).to eq("https://github.acme.com/github-apps/ubicloud-app/installations/new")
    expect(app.installation_settings_url(567)).to eq("https://github.acme.com/github-apps/ubicloud-app/installations/567")
  end

  it "can be restricted to a single project" do
    project = Project.create(name: "default")
    other_project = Project.create(name: "other")

    app = create_app("acme.ghe.com")
    expect(app.usable_by_project?(project)).to be true

    app.update(project_id: project.id)
    expect(app.usable_by_project?(project)).to be true
    expect(app.usable_by_project?(other_project)).to be false
  end
end
