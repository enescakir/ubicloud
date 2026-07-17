# frozen_string_literal: true

class Clover
  hash_branch("github") do |r|
    # Enterprise apps register their callback URL with their ubid as a path
    # segment, as one callback can serve multiple GitHub instances. Without
    # a segment, the callback is for our public app on github.com.
    github_callback = lambda do |github_app|
      no_authorization_needed
      oauth_code = typecast_params.str("code")
      installation_id = typecast_params.str("installation_id")
      setup_action = typecast_params.str("setup_action")
      code_response = Github.oauth_client(github_app).exchange_code_for_token(oauth_code)

      if (installation = GithubInstallation.with_github_installation_id(installation_id, github_app:))
        @project = installation.project
        authorize("Project:github", installation.project)
        flash["notice"] = "GitHub runner integration is already enabled for #{installation.project.name} project."
        Clog.emit("GitHub installation already exists", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect installation, "/runner"
      end

      unless (@project = project = current_account.projects_dataset.with_pk(session.delete("github_installation_project_id")))
        flash["error"] = "You should initiate the GitHub App installation request from the project's GitHub runner integration page."
        Clog.emit("GitHub callback failed due to lack of project in the session", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect "/project"
      end

      authorize("Project:github", project)

      if setup_action == "request"
        flash["notice"] = "The GitHub App installation request is awaiting approval from the GitHub organization's administrator. As GitHub will redirect your admin back to the Ubicloud console, the admin needs to have an Ubicloud account with the necessary permissions to finalize the installation. Please invite the admin to your project if they don't have an account yet."
        Clog.emit("GitHub installation initiated by non-admin user", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect user_path
      end

      unless (access_token = code_response[:access_token])
        flash["error"] = "GitHub App installation failed. For any questions or assistance, reach out to our team at support@ubicloud.com"
        Clog.emit("GitHub callback failed due to lack of permission", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect project, "/github"
      end

      begin
        user_client_options = {access_token:}
        user_client_options[:api_endpoint] = github_app.api_endpoint if github_app
        installation_response = Octokit::Client.new(**user_client_options).get("/user/installations")[:installations].find { it[:id].to_s == installation_id }
      rescue Octokit::Unauthorized => e
        installation_octokit_error = e
      end

      unless installation_response
        flash["error"] = "GitHub App installation failed. For any questions or assistance, reach out to our team at support@ubicloud.com"
        installation_failed = {id: installation_id, account_ubid: current_account.ubid}
        if installation_octokit_error
          Util.exception_to_hash(installation_octokit_error, into: installation_failed)
        end
        Clog.emit("GitHub callback failed due to lack of installation", {installation_failed:})
        r.redirect project, "/github"
      end

      unless project.active?
        flash["error"] = "GitHub runner integration is not allowed for inactive projects"
        Clog.emit("GitHub callback failed due to inactive project", {installation_failed: {id: installation_id, account_ubid: current_account.ubid}})
        r.redirect project, "/dashboard"
      end

      if github_app && !github_app.usable_by_project?(project)
        flash["error"] = "GitHub App installation failed. For any questions or assistance, reach out to our team at support@ubicloud.com"
        Clog.emit("GitHub callback failed due to project not allowed for the app", {installation_failed: {id: installation_id, account_ubid: current_account.ubid, github_app_host: github_app.host}})
        r.redirect project, "/github"
      end

      installation = GithubInstallation.create(
        installation_id:,
        name: installation_response[:account][:login] || installation_response[:account][:name],
        type: installation_response[:account][:type],
        project_id: project.id,
        github_app_id: github_app&.id,
      )

      flash["notice"] = "GitHub runner integration is enabled for #{project.name} project."
      r.redirect installation, "/runner"
    end

    r.get web?, "callback" do
      github_callback.call(nil)
    end

    r.get web?, "callback", :ubid_uuid do |github_app_id|
      github_app = GithubApp[github_app_id]
      check_found_object(github_app)
      github_callback.call(github_app)
    end
  end
end
