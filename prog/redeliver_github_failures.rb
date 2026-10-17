# frozen_string_literal: true

class Prog::RedeliverGithubFailures < Prog::Base
  frame_accessor :delivery_ids, :last_check_at

  label def wait
    last_check_time = Time.new(last_check_at)
    remaining_seconds = 2 * 60 - (Time.now - last_check_time)
    nap remaining_seconds.to_i + 1 if remaining_seconds > 0
    failures = failed_deliveries(last_check_time)
    # The GitHub client has a 5 second timeout, and Strand::LEASE_EXPIRATION is 120 seconds.
    # To stay within safe limits, we redeliver in batches of 25.
    failures.each_slice(25) do |deliveries|
      bud Prog::RedeliverGithubFailures, {"delivery_ids" => deliveries.map { it[:id] }}, "redeliver"
    end
    self.last_check_at = Time.now.to_s
    hop_wait_redelivers
  end

  label def wait_redelivers
    register_deadline("wait", 30 * 60)
    reap(:wait)
  end

  label def redeliver
    # Drop each delivery from the frame after it is redelivered, so a rate
    # limited run continues from where it stopped instead of redelivering the
    # same failures again.
    while (delivery_id = delivery_ids.first)
      begin
        client.post("/app/hook/deliveries/#{delivery_id}/attempts")
      rescue Octokit::TooManyRequests, Octokit::AbuseDetected => ex
        # The secondary rate limit reports "retry-after", the primary one
        # reports the reset time in the rate limit headers.
        retry_after = ex.response_headers&.fetch("retry-after", nil)
        seconds = (retry_after || ex.context&.resets_in).to_i.clamp(60, 60 * 60)
        Clog.emit("github redelivery is rate limited", {github_redelivery_rate_limited: {remaining: delivery_ids.count, nap: seconds}})
        nap seconds
      end
      self.delivery_ids = delivery_ids.drop(1)
    end
    pop "redelivered failures"
  end

  def client
    @client ||= Github.app_client
  end

  def failed_deliveries(since, max_page = 100)
    all_deliveries = client.list_app_hook_deliveries
    page = 1
    while (next_url = client.last_response.rels[:next]&.href) && (since < all_deliveries.last[:delivered_at])
      break if page >= max_page
      page += 1
      all_deliveries += client.get(next_url)
    end
    failures = all_deliveries
      .reject { it[:delivered_at] < since }
      .group_by { it[:guid] }
      .values
      .reject { |group| group.any? { it[:status] == "OK" } }
      .map { |group| group.max_by { it[:delivered_at] } }
    Clog.emit("fetched github deliveries", {fetched_github_deliveries: {total: all_deliveries.count, failed: failures.count, status: failures.map { it[:status] }.tally, page:, since:}})
    failures
  end
end
