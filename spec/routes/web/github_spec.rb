# frozen_string_literal: true

require_relative "spec_helper"
require "octokit"

RSpec.describe Clover, "github" do
  let(:user) { create_account }
  let(:project) { user.create_project_with_default_policy("project-1") }
  let(:installation) { GithubInstallation.create(installation_id: 123, project_id: project.id, name: "test-user", type: "User") }
  let(:oauth_client) { instance_double(Octokit::Client) }
  let(:adhoc_client) { instance_double(Octokit::Client) }

  before do
    login(user.email)

    allow(Config).to receive(:github_app_name).and_return("runner-app")
    allow(Github).to receive(:oauth_client).and_return(oauth_client)
    allow(Octokit::Client).to receive(:new).and_return(adhoc_client)
  end

  it "redirects to github page if already installed" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})

    visit "/github/callback?code=123123&installation_id=#{installation.installation_id}"

    expect(page.title).to eq("Ubicloud - Active Runners")
    expect(page).to have_flash_notice("GitHub runner integration is already enabled for #{project.name} project.")
  end

  it "raises forbidden when does not have permissions to access already enabled installation" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    project
    installation
    AccessControlEntry.dataset.update(action_id: ActionType::NAME_MAP["Project:view"])

    visit "/github/callback?code=123123&installation_id=#{installation.installation_id}"

    expect(page.title).to eq("Ubicloud - Forbidden")
    expect(page.status_code).to eq(403)
    expect(page).to have_content "Forbidden"
  end

  it "fails if project not found at session" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})

    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Projects")
    expect(page).to have_flash_error("You should initiate the GitHub App installation request from the project's GitHub runner integration page.")
  end

  it "raises forbidden when does not have permissions to the project in session" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})

    visit "/set_github_installation_project_id/#{project.ubid}"
    AccessControlEntry.dataset.destroy
    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Forbidden")
    expect(page.status_code).to eq(403)
    expect(page).to have_content "Forbidden"
  end

  it "redirects to user management page if it requires approval" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({})

    visit "/set_github_installation_project_id/#{project.ubid}"
    visit "/github/callback?code=123123&setup_action=request"

    expect(page.title).to eq("Ubicloud - #{project.name} - Users")
    expect(page).to have_flash_notice(/.*awaiting approval from the GitHub organization's administrator.*/)
  end

  it "fails if oauth code is invalid" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("invalid").and_return({})

    visit "/set_github_installation_project_id/#{project.ubid}"
    visit "/github/callback?code=invalid"

    expect(page.title).to eq("Ubicloud - GitHub Runners Integration")
    expect(page).to have_flash_error(/^GitHub App installation failed.*/)
  end

  it "fails if installation not found" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: []})

    visit "/set_github_installation_project_id/#{project.ubid}"
    visit "/github/callback?code=123123"

    expect(page.title).to eq("Ubicloud - GitHub Runners Integration")
    expect(page).to have_flash_error(/^GitHub App installation failed.*/)
  end

  it "fails if Octokit::Unauthorized is raised when looking for installation" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_raise(Octokit::Unauthorized)

    visit "/set_github_installation_project_id/#{project.ubid}"
    visit "/github/callback?code=123123"

    expect(page.title).to eq("Ubicloud - GitHub Runners Integration")
    expect(page).to have_flash_error(/^GitHub App installation failed.*/)
  end

  it "fails if the project is not active" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-user", type: "User"}}]})

    visit "/set_github_installation_project_id/#{project.ubid}"
    suspended_account = Account.create(email: "suspend@example.com", suspended_at: Time.now)
    project.add_account(suspended_account)
    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - project-1 Dashboard")
    expect(page).to have_flash_error("GitHub runner integration is not allowed for inactive projects")
  end

  it "creates installation with project from session" do
    expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
    expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-user", type: "User"}}]})

    visit "/set_github_installation_project_id/#{project.ubid}"
    visit "/github/callback?code=123123&installation_id=345"

    expect(page.title).to eq("Ubicloud - Active Runners")
    expect(page).to have_flash_notice("GitHub runner integration is enabled for #{project.name} project.")
    installation = GithubInstallation[installation_id: 345]
    expect(installation.name).to eq("test-user")
    expect(installation.type).to eq("User")
    expect(installation.project_id).to eq(project.id)
    expect(installation.github_app_id).to be_nil
  end

  context "with a GitHub Enterprise app" do
    let(:github_app) do
      GithubApp.create(host: "acme.ghe.com", slug: "ubicloud-app", app_id: 654321, client_id: "client-id", client_secret: "client-secret", private_key: "private-key", webhook_secret: "webhook-secret")
    end

    it "creates installation for the app resolved from the path" do
      expect(Github).to receive(:oauth_client).with(github_app).and_return(oauth_client)
      expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
      expect(Octokit::Client).to receive(:new).with(access_token: "123", api_endpoint: "https://api.acme.ghe.com/").and_return(adhoc_client)
      expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-org", type: "Organization"}}]})

      visit "/set_github_installation_project_id/#{project.ubid}"
      visit "/github/callback/#{github_app.ubid}?code=123123&installation_id=345"

      expect(page.title).to eq("Ubicloud - Active Runners")
      created_installation = GithubInstallation[installation_id: 345]
      expect(created_installation.github_app_id).to eq(github_app.id)
      expect(created_installation.host).to eq("acme.ghe.com")
    end

    it "fails if the app is not registered" do
      unknown_app_ubid = UBID.generate(UBID::TYPE_GITHUB_APP).to_s

      visit "/github/callback/#{unknown_app_ubid}?code=123123&installation_id=345"

      expect(page.status_code).to eq(404)
    end

    it "does not treat an enterprise installation as existing github.com installation with the same id" do
      installation
      expect(Github).to receive(:oauth_client).with(github_app).and_return(oauth_client)
      expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
      expect(Octokit::Client).to receive(:new).with(access_token: "123", api_endpoint: "https://api.acme.ghe.com/").and_return(adhoc_client)
      expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: installation.installation_id, account: {login: "test-org", type: "Organization"}}]})

      visit "/set_github_installation_project_id/#{project.ubid}"
      visit "/github/callback/#{github_app.ubid}?code=123123&installation_id=#{installation.installation_id}"

      expect(page.title).to eq("Ubicloud - Active Runners")
      expect(page).to have_flash_notice("GitHub runner integration is enabled for #{project.name} project.")
      expect(GithubInstallation.where(installation_id: installation.installation_id).count).to eq(2)
    end

    it "fails if the app is restricted to another project" do
      github_app.update(project_id: user.create_project_with_default_policy("project-2").id)
      expect(Github).to receive(:oauth_client).with(github_app).and_return(oauth_client)
      expect(oauth_client).to receive(:exchange_code_for_token).with("123123").and_return({access_token: "123"})
      expect(Octokit::Client).to receive(:new).with(access_token: "123", api_endpoint: "https://api.acme.ghe.com/").and_return(adhoc_client)
      expect(adhoc_client).to receive(:get).with("/user/installations").and_return({installations: [{id: 345, account: {login: "test-org", type: "Organization"}}]})

      visit "/set_github_installation_project_id/#{project.ubid}"
      visit "/github/callback/#{github_app.ubid}?code=123123&installation_id=345"

      expect(page.title).to eq("Ubicloud - GitHub Runners Integration")
      expect(page).to have_flash_error(/^GitHub App installation failed.*/)
      expect(GithubInstallation[installation_id: 345]).to be_nil
    end
  end
end
