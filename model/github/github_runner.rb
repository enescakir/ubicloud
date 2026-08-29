# frozen_string_literal: true

require_relative "../../model"

class GithubRunner < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :installation, class: :GithubInstallation
  many_to_one :repository, class: :GithubRepository, read_only: true
  many_to_one :vm, read_only: true
  one_through_one :project, join_table: :github_installation, left_key: :id, left_primary_key: :installation_id, read_only: true

  plugin ResourceMethods, redacted_columns: :workflow_job
  plugin SemaphoreMethods, :destroy, :skip_deregistration, :not_upgrade_premium, :spill_over, :spare_runner_provisioned
  include HealthMonitorMethods

  NOT_VM_ALLOCATED_RUNNER_LABELS = %w[start wait_concurrency_limit apply_custom_label_quota].freeze

  # Collect everything log_duration reports about the runner's vm in a single
  # query. This runs on the webhook hot path, where walking the associations
  # one by one costs seven round trips per event.
  VM_LOG_VALUES_DS = DB[:vm]
    .left_join(:vm_host, id: Sequel[:vm][:vm_host_id])
    .left_join(:aws_instance, id: Sequel[:vm][:id])
    .left_join(
      DB[:vm_storage_volume]
        .where(vm_id: Sequel[:vm][:id])
        .order(Sequel.desc(:boot))
        .limit(1)
        .select(:vm_id, :boot_image_id, :vhost_block_backend_id)
        .lateral,
      {vm_id: Sequel[:vm][:id]}, table_alias: :vsv,
    )
    .left_join(:boot_image, id: Sequel[:vsv][:boot_image_id])
    .left_join(:vhost_block_backend, id: Sequel[:vsv][:vhost_block_backend_id])
    .where(Sequel[:vm][:id] => :$vm_id)
    .select(
      Sequel[:vm][:arch],
      Sequel[:vm][:cores],
      Sequel[:vm][:vcpus],
      Sequel[:vm][:pool_id],
      Sequel[:vm][:vm_host_id],
      Sequel[:vm][:boot_image].as(:vm_boot_image),
      Sequel[:vm_host][:data_center],
      Sequel[:aws_instance][:id].as(:aws_instance_id),
      Sequel[:aws_instance][:instance_id],
      Sequel[:boot_image][:version].as(:boot_image_version),
      Sequel[:vhost_block_backend][:version_code],
    )
    .freeze

  dataset_module do
    def total_active_runner_vcpus
      left_join(:strand, id: Sequel[:github_runner][:id])
        .exclude(Sequel[:strand][:label] => NOT_VM_ALLOCATED_RUNNER_LABELS)
        .select_map(Sequel[:github_runner][:label])
        .sum { Github.runner_labels[it]["vcpus"] }
    end

    def metal_active_runner_vcpus
      ds = self
      if (aws_location_id = Config.github_runner_aws_location_id)
        ds = ds.exclude(location_id: aws_location_id)
      end
      ds.total_active_runner_vcpus
    end

    def aws_active_runner_vcpus
      return 0 unless (aws_location_id = Config.github_runner_aws_location_id)
      where(location_id: aws_location_id)
        .total_active_runner_vcpus
    end
  end

  def label_data
    @label_data ||= Github.runner_labels[label]
  end

  def repository_url
    "http://github.com/#{repository_name}"
  end

  def run_url
    "#{repository_url}/actions/runs/#{workflow_job["run_id"]}"
  end

  def job_url
    "#{run_url}/job/#{workflow_job["id"]}"
  end

  def runner_url
    "#{repository_url}/settings/actions/runners/#{runner_id}" if runner_id
  end

  def log_duration(message, duration)
    values = {ubid:, label:, repository_name:, duration: duration.round(3), conclusion: workflow_job&.dig("conclusion")}
    if vm_id && (row = VM_LOG_VALUES_DS.call(:first, vm_id:))
      values.merge!(vm_ubid: UBID.to_ubid(vm_id), arch: row[:arch], cores: row[:cores], vcpus: row[:vcpus], boot_image: row[:boot_image_version] || row[:vm_boot_image])
      if (version_code = row[:version_code])
        values[:vhost_block_backend_version] = VhostBlockBackend.version_string(version_code)
      end
      if (vm_host_id = row[:vm_host_id])
        values[:vm_host_ubid] = UBID.to_ubid(vm_host_id)
        values[:data_center] = row[:data_center]
      end
      values[:instance_id] = row[:instance_id] if row[:aws_instance_id]
      values[:vm_pool_ubid] = UBID.to_ubid(row[:pool_id]) if row[:pool_id]
    end
    Clog.emit(message, {message => values})
  end

  def provision_spare_runner(force: false)
    return if !force && spare_runner_provisioned_set?
    incr_spare_runner_provisioned
    Prog::Github::GithubRunnerNexus.assemble(installation, repository_name:, label:).subject
  end

  def init_health_monitor_session
    {
      ssh_session: vm.sshable.start_fresh_session,
    }
  end

  def check_pulse(session:, previous_pulse:)
    reading = begin
      available_memory = session[:ssh_session].exec!("awk '/MemAvailable/ {print $2}' /proc/meminfo").chomp
      "up"
    rescue
      "down"
    end
    aggregate_readings(previous_pulse:, reading:, data: {available_memory:})
  end

  def page_on_sshable_failure?
    false
  end

  def custom_label
    GithubCustomLabel.first(name: actual_label, installation_id:)
  end

  def strand_label
    strand&.label
  end
end

# Table: github_runner
# Columns:
#  id              | uuid                     | PRIMARY KEY
#  installation_id | uuid                     |
#  repository_name | text                     | NOT NULL
#  label           | text                     | NOT NULL
#  vm_id           | uuid                     |
#  runner_id       | bigint                   |
#  created_at      | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  ready_at        | timestamp with time zone |
#  workflow_job    | jsonb                    |
#  repository_id   | uuid                     |
#  allocated_at    | timestamp with time zone |
#  billed_vm_size  | text                     |
#  actual_label    | text                     |
#  location_id     | uuid                     |
# Indexes:
#  github_runner_pkey                  | PRIMARY KEY btree (id)
#  github_runner_vm_id_key             | UNIQUE btree (vm_id)
#  github_runner_installation_id_index | btree (installation_id)
# Check constraints:
#  location_id_and_vm_id_set_together | (location_id IS NOT NULL AND vm_id IS NOT NULL OR location_id IS NULL AND vm_id IS NULL)
# Foreign key constraints:
#  github_runner_installation_id_fkey | (installation_id) REFERENCES github_installation(id)
#  github_runner_location_id_fkey     | (location_id) REFERENCES location(id)
#  github_runner_repository_id_fkey   | (repository_id) REFERENCES github_repository(id)
