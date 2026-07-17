# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "GithubApp" do
  include AdminModelSpecHelper

  before do
    @instance = create_github_app
    admin_account_setup_and_login
  end

  it "displays the GithubApp instance page correctly" do
    click_link "GithubApp"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubApp"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - GithubApp #{@instance.ubid}"
  end
end
