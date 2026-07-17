# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GithubInstallation do
  subject(:installation) {
    described_class.create(installation_id: 123, project_id: Project.create(name: "default").id, name: "test-user", type: "User")
  }

  it "returns sum of used vm cores" do
    vms = [2, 4, 8].map { create_vm(cores: it) }

    # let's not create runner for the last vm
    vms[..1].each do |vm|
      gr = GithubRunner.create(installation_id: installation.id, vm_id: vm.id, repository_name: "test-repo", label: "ubicloud-standard-#{vm.cores}")
      Strand.create_with_id(gr, prog: "Github::RunnerNexus", label: "allocate_vm")
    end

    expect(installation.total_active_runner_vcpus).to eq(6)
  end

  it "returns sum of used vm cores for arm64" do
    vms = [2, 4].map { create_vm(cores: it, arch: "arm64") }

    vms.each do |vm|
      gr = GithubRunner.create(installation_id: installation.id, vm_id: vm.id, repository_name: "test-repo", label: "ubicloud-standard-#{vm.cores}-arm")
      Strand.create_with_id(gr, prog: "Github::RunnerNexus", label: "allocate_vm")
    end

    expect(installation.total_active_runner_vcpus).to eq(6)
  end

  describe "#standard_runner_allowed?" do
    it "returns true if created before 2026-06-05" do
      installation.update(created_at: Time.utc(2026, 6, 4))
      expect(installation.standard_runner_allowed?).to be true
    end

    it "returns false if created on or after 2026-06-05" do
      installation.update(created_at: Time.utc(2026, 6, 6))
      expect(installation.standard_runner_allowed?).to be false
    end
  end

  describe "#installation_settings_url" do
    it "returns the public app URL if the installation has no app" do
      allow(Config).to receive(:github_app_name).and_return("runner-app")
      expect(installation.installation_settings_url).to eq("https://github.com/apps/runner-app/installations/#{installation.installation_id}")
    end

    it "returns the enterprise app URL if the installation has an app" do
      github_app = GithubApp.create(host: "acme.ghe.com", slug: "ubicloud-app", app_id: 654321, client_id: "client-id", client_secret: "client-secret", private_key: "private-key", webhook_secret: "webhook-secret")
      installation.update(github_app_id: github_app.id)
      expect(installation.installation_settings_url).to eq("https://acme.ghe.com/apps/ubicloud-app/installations/#{installation.installation_id}")
    end
  end

  describe "#cache_storage_gib" do
    it "returns effective quota if the premium is not enabled" do
      installation.update(allocator_preferences: {})
      expect(installation.cache_storage_gib).to eq(30)
    end

    it "returns 100GB if the premium is enabled" do
      expect(installation.cache_storage_gib).to eq(100)
    end

    it "returns effective quota if it is larger than premium" do
      installation.project.add_quota(quota_id: ProjectQuota.default_quotas["GithubRunnerCacheStorage"]["id"], value: 300)
      expect(installation.cache_storage_gib).to eq(300)
    end
  end
end
