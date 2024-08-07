# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_prefix, "load-balancer") do |r|
    load_balancer_endpoint_helper = Routes::Common::LoadBalancerHelper.new(app: self, request: r, user: @current_user, location: nil, resource: nil)

    r.get true do
      load_balancer_endpoint_helper.list
    end

    r.post true do
      load_balancer_endpoint_helper.post(name: r.params["name"])
    end

    r.on "create" do
      r.get true do
        load_balancer_endpoint_helper.view_create_page
      end
    end
  end
end
