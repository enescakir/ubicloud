# frozen_string_literal: true

class CloverApi
  hash_branch(:project_prefix, "postgres") do |r|
    r.get true do
      result = @project.postgres_resources_dataset.authorized(@current_user.id, "Postgres:view").eager(:semaphores, :strand).paginated_result(
        start_after: r.params["start_after"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: Serializers::Postgres.serialize(result[:records]),
        count: result[:count]
      }
    end
  end
end
