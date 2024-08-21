# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Github::GithubRepositoryNexus < Prog::Base
  subject_is :github_repository

  semaphore :destroy

  def self.assemble(installation, name, default_branch)
    DB.transaction do
      repository = GithubRepository.new_with_id(installation_id: installation.id, name: name)
      repository.skip_auto_validations(:unique) do
        updates = {last_job_at: Time.now}
        updates[:default_branch] = default_branch if default_branch
        repository.insert_conflict(target: [:installation_id, :name], update: updates).save_changes
      end
      Strand.new(prog: "Github::GithubRepositoryNexus", label: "wait") { _1.id = repository.id }
        .insert_conflict(target: :id).save_changes
    end
  end

  def client
    @client ||= Github.installation_client(github_repository.installation.installation_id).tap { _1.auto_paginate = true }
  end

  # We dynamically adjust the polling interval based on the remaining rate
  # limit. It's 5 minutes by default, but it can be increased if the rate limit
  # is low.
  def polling_interval
    @polling_interval ||= 5 * 60
  end

  def check_queued_jobs
    queued_runs = client.repository_workflow_runs(github_repository.name, {status: "queued"})[:workflow_runs]
    Clog.emit("polled queued runs") { {polled_queued_runs: {repository_name: github_repository.name, count: queued_runs.count}} }

    # We check the rate limit after the first API call to avoid unnecessary API
    # calls to fetch only the rate limit. Every response includes the rate limit
    # information in the headers.
    remaining_quota = client.rate_limit.remaining / client.rate_limit.limit.to_f
    if remaining_quota < 0.1
      Clog.emit("low remaining quota") { {low_remaining_quota: {repository_name: github_repository.name, limit: client.rate_limit.limit, remaining: client.rate_limit.remaining}} }
      @polling_interval = (client.rate_limit.resets_at - Time.now).to_i
      return
    end

    queued_labels = Hash.new(0)
    queued_runs.each do |run|
      jobs = client.workflow_run_attempt_jobs(github_repository.name, run[:id], run[:run_attempt])[:jobs]

      jobs.each do |job|
        next if job[:status] != "queued"
        next unless (label = job[:labels].find { Github.runner_labels.key?(_1) })
        queued_labels[label] += 1
      end
    end

    queued_labels.each do |label, count|
      idle_runner_count = github_repository.runners_dataset.where(label: label, workflow_job: nil).count
      # The calculation of the required_runner_count isn't atomic because it
      # requires multiple API calls and database queries. However, it will
      # eventually settle on the correct value. If we create more runners than
      # necessary, the excess will be recycled after 5 minutes at no extra cost
      # to the customer. If fewer runners are created than needed, the system
      # will generate more in the next cycle.
      next if (required_runner_count = count - idle_runner_count) && required_runner_count <= 0

      Clog.emit("extra runner needed") { {needed_extra_runner: {repository_name: github_repository.name, label: label, count: required_runner_count}} }

      required_runner_count.times do
        Prog::Vm::GithubRunner.assemble(
          github_repository.installation,
          repository_name: github_repository.name,
          label: label
        )
      end
    end

    @polling_interval = (remaining_quota < 0.5) ? 15 * 60 : 5 * 60
  end

  def cleanup_cache
    # Destroy cache entries not accessed in last 7 days or
    # created more than 7 days ago and not accessed yet.
    seven_days_ago = Time.now - 7 * 24 * 60 * 60
    github_repository.cache_entries_dataset
      .where { (last_accessed_at < seven_days_ago) | ((last_accessed_at =~ nil) & (created_at < seven_days_ago)) }
      .destroy

    # Destroy oldest cache entries if the total usage exceeds the limit.
    total_usage = github_repository.cache_entries_dataset.sum(:size).to_i
    if total_usage > GithubRepository::CACHE_SIZE_LIMIT
      github_repository.cache_entries_dataset.order(:created_at).each do |oldest_entry|
        break if total_usage <= GithubRepository::CACHE_SIZE_LIMIT
        oldest_entry.destroy
        total_usage -= oldest_entry.size
      end
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        register_deadline(nil, 5 * 60)
        hop_destroy
      end
    end
  end

  label def wait
    cleanup_cache if github_repository.access_key
    nap 15 * 60 if Time.now - github_repository.last_job_at > 6 * 60 * 60

    begin
      check_queued_jobs if Config.enable_github_workflow_poller
    rescue Octokit::NotFound
      Clog.emit("not found repository") { {not_found_repository: {repository_name: github_repository.name}} }
      if github_repository.runners.count == 0
        github_repository.incr_destroy
        nap 0
      end
    end

    # check_queued_jobs may have changed the default polling interval based on
    # the remaining rate limit.
    nap polling_interval
  end

  label def destroy
    decr_destroy

    unless github_repository.runners.empty?
      Clog.emit("Cannot destroy repository with active runners") { {not_destroyed_repository: {repository_name: github_repository.name}} }
      nap 5 * 60
    end

    github_repository.destroy

    pop "github repository destroyed"
  end
end
