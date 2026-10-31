# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresServer do
  subject(:postgres_server) {
    described_class.create(
      timeline:, resource:, vm_id: vm.id, is_representative: true,
      synchronization_status: "ready", timeline_access: "push", version: "16",
    )
  }

  let(:project) { Project.create(name: "postgres-server") }
  let(:project_service) { Project.create(name: "postgres-service") }

  let(:timeline) { create_postgres_timeline(location_id: location.id) }

  let(:resource) { create_postgres_resource(project:, location_id: location.id) }

  let(:private_subnet) {
    PrivateSubnet.create(
      name: "postgres-subnet", project:, location:,
      net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
      net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64"),
    )
  }

  let(:vm) { create_hosted_vm(project, private_subnet, "dummy-vm") }

  let(:location) {
    Location.create(
      name: "us-west-2",
      project:,
      display_name: "us-west-2",
      ui_name: "us-west-2",
      provider: "ubicloud",
      visible: true,
    )
  }

  before do
    allow(Config).to receive(:postgres_service_project_id).and_return(project_service.id)
  end

  describe "#configure" do
    before do
      resource.update(flavor: PostgresResource::Flavor::STANDARD, cert_auth_users: [])
      MinioCluster.create(
        project_id: Config.postgres_service_project_id, location:, name: "pgminio", admin_user: "root", admin_password: "root",
      )
    end

    let(:standby) {
      postgres_server
      described_class.create(
        timeline:, resource:, vm_id: create_hosted_vm(project, private_subnet, "standby").id,
        synchronization_status: "ready", timeline_access: "fetch", version: "16",
      )
    }

    def create_standby_resource
      create_postgres_resource(project:, location_id: location.id).update(ha_type: PostgresResource::HaType::SYNC)
    end

    it "does not set archival related configs if blob storage is not configured" do
      expect(Config).to receive(:postgres_service_project_id).and_return(nil).at_least(:once)
      expect(postgres_server.configure_hash[:configs]).not_to include(:archive_mode, :archive_timeout, :archive_command, :synchronous_standby_names, :primary_conninfo, :recovery_target_time, :restore_command)
    end

    it "sets the default configs for a primary on PostgreSQL 16" do
      result = postgres_server.configure_hash
      configs = result[:configs]
      expect(configs).to include(
        :archive_mode, :archive_timeout,
        :archive_command => "'/usr/bin/walg-daemon-client /tmp/wal-g wal-push %f'",
        "log_line_prefix" => "'%m [%p:%l] (%x,%v): host=%r,db=%d,user=%u,app=%a,client=%h '",
        "wal_compression" => "lz4",
        "default_toast_compression" => "lz4",
        "recovery_init_sync_method" => "syncfs",
        "wal_keep_size" => "96MB",
        "max_connections" => Validation::PostgresConfigValidator.new("16").default("max_connections").to_s,
      )
      expect(configs.keys & ["allow_alter_system", "autovacuum_max_workers", "autovacuum_vacuum_max_threshold", :synchronized_standby_slots, :primary_conninfo, :restore_command]).to eq []
      expect(result[:strict_overcommit]).to be true
    end

    it "sets allow_alter_system and synchronized_standby_slots on PostgreSQL 17" do
      postgres_server.update(version: "17")
      expect(postgres_server.configure_hash[:configs]).to include("allow_alter_system" => "off", :synchronized_standby_slots => "''")
    end

    it "sets synchronous_standby_names for sync replication mode" do
      postgres_server
      resource.update(ha_type: PostgresResource::HaType::SYNC)

      described_class.create(
        timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "standby1").id,
        synchronization_status: "catching_up", timeline_access: "fetch", version: "16",
      )
      standby2 = described_class.create(
        timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "standby2").id,
        synchronization_status: "ready", timeline_access: "fetch", version: "16",
      )

      expect(postgres_server.configure_hash[:configs]).to include(synchronous_standby_names: "'ANY 1 (#{standby2.ubid})'")
    end

    it "sets synchronous_standby_names as empty if there is no caught up standby" do
      resource.update(ha_type: PostgresResource::HaType::SYNC)

      described_class.create(
        timeline:, resource: create_standby_resource, vm_id: create_hosted_vm(project, private_subnet, "standby1").id, is_representative: true,
        synchronization_status: "catching_up", timeline_access: "fetch", version: "16",
      )
      described_class.create(
        timeline:, resource: create_standby_resource, vm_id: create_hosted_vm(project, private_subnet, "standby2").id, is_representative: true,
        synchronization_status: "catching_up", timeline_access: "fetch", version: "16",
      )

      expect(postgres_server.configure_hash[:configs]).not_to include(:synchronous_standby_names)
    end

    it "sets configs that are specific to standby, keeping more WAL so the archive can be backfilled after a failover" do
      configs = standby.configure_hash[:configs]
      expect(configs).to include(
        :primary_conninfo => "'#{resource.replication_connection_string(application_name: standby.ubid)}'",
        :restore_command => "'/usr/bin/wal-g wal-fetch %f %p --config /etc/postgresql/wal-g.env'",
        "wal_keep_size" => "2GB",
      )
      expect(configs.keys & [:primary_slot_name, :recovery_target_time]).to eq []

      standby.vm.update(family: "burstable")
      expect(standby.configure_hash[:configs]).to include("wal_keep_size" => "512MB")
    end

    it "sets primary_slot_name to ubid on standby when physical slot ready" do
      standby.update(physical_slot_ready_id: postgres_server.id)
      expect(standby.configure_hash.dig(:configs, :primary_slot_name)).to eq("'#{standby.ubid}'")
    end

    it "sets configs that are specific to PITR-by-time restore" do
      postgres_server.update(timeline_access: "fetch")
      resource.update(restore_target: Time.now)
      expect(postgres_server.configure_hash[:configs]).to include(:recovery_target_time, :restore_command)
    end

    it "omits recovery targets for unarchive: archive tail may sit in unarchived segment" do
      postgres_server.update(timeline_access: "fetch")
      postgres_server.incr_unarchive
      configs = postgres_server.configure_hash[:configs]
      expect(configs).to include(:restore_command)
      expect(configs.keys & [:recovery_target_lsn, :recovery_target_time]).to eq []
    end

    it "puts extra logging options for AWS" do
      location.update(provider: "aws")
      expect(postgres_server.configure_hash[:configs]).to include(:log_connections, :log_disconnections)
    end

    it "sets max_wal_size to 4% of storage, between 5GB and 256GB" do
      volume = VmStorageVolume.create(vm:, disk_index: 0, boot: false, size_gib: 32)
      max_wal_sizes = [32, 1875, 7500].map do |size_gib|
        volume.update(size_gib:)
        postgres_server.vm.vm_storage_volumes(reload: true)
        postgres_server.configure_hash[:configs]["max_wal_size"]
      end
      expect(max_wal_sizes).to eq ["5GB", "75GB", "256GB"]
    end

    it "lists only the subnet of the user NIC for pg_hba" do
      mgmt_subnet = PrivateSubnet.create(
        name: "mgmt-subnet", project: project_service, location:,
        net4: NetAddr::IPv4Net.parse("100.64.0.0/20"),
        net6: NetAddr::IPv6Net.parse("fd5a:0f1e:2b3c:4d5e::/64"),
      )
      Prog::Vnet::NicNexus.assemble(mgmt_subnet.id, name: "dummy-vm-mgmt-nic", is_management: true).subject.update(vm_id: vm.id)

      expect(postgres_server.configure_hash[:private_subnets]).to eq([{net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64"}])
    end

    it "sets strict_overcommit to false when skip_strict_memory_overcommit semaphore is set" do
      resource.incr_skip_strict_memory_overcommit
      expect(postgres_server.configure_hash[:strict_overcommit]).to be false
    end

    it "passes ubicloud.shared_memory_percent through to the guest config" do
      vm.update(memory_gib: 32)
      resource.update(user_config: {"ubicloud.shared_memory_percent" => "50", "work_mem" => "32MB"})
      expect(postgres_server.configure_hash[:user_config]).to eq("ubicloud.shared_memory_percent" => "50", "work_mem" => "32MB")
    end

    it "downgrades only serializable default_transaction_isolation to repeatable read on standbys" do
      resource.update(user_config: {"default_transaction_isolation" => "serializable", "max_connections" => "100"})
      expect(postgres_server.configure_hash[:user_config]).to eq("default_transaction_isolation" => "serializable", "max_connections" => "100")
      expect(standby.configure_hash[:user_config]).to eq("default_transaction_isolation" => "repeatable read", "max_connections" => "100")

      resource.update(user_config: {"default_transaction_isolation" => "repeatable read"})
      expect(standby.configure_hash[:user_config]).to eq("default_transaction_isolation" => "repeatable read")
    end

    it "scales the autovacuum GUCs with the VM size on PostgreSQL 18+" do
      postgres_server.update(version: "18")
      # max_workers is vcpus.clamp(3, 8), so 1c exercises the floor and 16c/48c
      # the cap. work_mem is 1/4 of VM memory split across those workers.
      keys = %w[autovacuum_vacuum_cost_limit autovacuum_naptime autovacuum_max_workers autovacuum_work_mem autovacuum_vacuum_cost_delay autovacuum_vacuum_max_threshold]
      scaled = [[1, 4], [4, 16], [16, 64], [48, 192]].map do |vcpus, memory_gib|
        postgres_server.vm.update(vcpus:, memory_gib:)
        postgres_server.configure_hash[:configs].values_at(*keys)
      end
      expect(scaled).to eq [
        ["200", "60s", "3", "341MB", "2ms", "50000000"],
        ["200", "30s", "4", "1024MB", "2ms", "50000000"],
        ["800", "30s", "8", "2048MB", "2ms", "50000000"],
        ["2400", "30s", "8", "6144MB", "2ms", "50000000"],
      ]
    end

    # The trigger thresholds are deliberately left at the PostgreSQL defaults of
    # 0.2. Lowering them to 0.1 doubles how often a large table becomes eligible,
    # and vacuum I/O scales with the number of passes rather than with the amount
    # of garbage each pass finds, because a pass re-reads most of the heap either
    # way. Benchmarking showed that halving them was the dominant cause of the
    # extra I/O, while cost_limit was already saturating the disk.
    it "leaves the autovacuum trigger scale factors at the PostgreSQL defaults" do
      postgres_server.update(version: "18")
      configs = postgres_server.configure_hash[:configs]
      expect(configs.keys & ["autovacuum_vacuum_scale_factor", "autovacuum_vacuum_insert_scale_factor"]).to eq []
    end

    it "sizes autovacuum_work_mem for the workers that actually run below PostgreSQL 18" do
      postgres_server.vm.update(vcpus: 48, memory_gib: 192)
      configs = postgres_server.configure_hash[:configs]
      expect(configs).to include("autovacuum_vacuum_cost_delay" => "2ms", "autovacuum_vacuum_cost_limit" => "2400", "autovacuum_naptime" => "30s")
      # Three workers is the pre-18 default and the count we leave in place, so
      # the three together stay within 1/4 of VM memory. Sizing off the scaled
      # count instead would drop this below the maintenance_work_mem these
      # servers inherit today.
      expect(configs).to include("autovacuum_work_mem" => "16384MB", "maintenance_work_mem" => "12288MB")
    end

    it "lets a customer user_config value override the scaled autovacuum default per-GUC" do
      postgres_server.vm.update(vcpus: 4, memory_gib: 16)
      resource.update(user_config: {"autovacuum_vacuum_cost_limit" => "9999"})
      result = postgres_server.configure_hash
      # The scaled default stays in the platform configs layer while the customer
      # value goes to user_config; the config renderer loads the platform file
      # first, so the customer value is the one that takes effect.
      expect(result[:configs]).to include("autovacuum_vacuum_cost_limit" => "200")
      expect(result[:user_config]).to eq("autovacuum_vacuum_cost_limit" => "9999")
    end
  end

  describe "restart-sensitive parameter handling" do
    let(:standby) {
      described_class.create(
        timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "standby").id,
        synchronization_status: "ready", timeline_access: "fetch", version: "16", is_representative: false,
      )
    }

    let(:psql_command) { "PGOPTIONS='-c statement_timeout=60s' psql -U postgres -d postgres -t --csv -v 'ON_ERROR_STOP=1'" }
    let(:settings_query) { %(SELECT "name", "setting" FROM "pg_settings" WHERE ("name" IN ('max_connections', 'max_worker_processes', 'max_wal_senders', 'max_prepared_transactions', 'max_locks_per_transaction'))) }

    def running(values)
      PostgresServer::RESTART_SENSITIVE_PARAMS.zip(values).to_h
    end

    def running_csv(values)
      running(values).map { |name, value| "#{name},#{value}" }.join("\n")
    end

    describe "#replication_parent_server" do
      it "is nil for a standalone primary" do
        expect(postgres_server.replication_parent_server).to be_nil
      end

      it "is the resource representative for an HA standby" do
        postgres_server
        expect(standby.replication_parent_server).to eq(postgres_server)
      end

      it "is the parent resource's representative for a read replica representative" do
        postgres_server
        replica_resource = create_postgres_resource(project:, location_id: location.id)
        replica_resource.update(parent_id: resource.id)
        replica = described_class.create(
          timeline:, resource_id: replica_resource.id, vm_id: create_hosted_vm(project, private_subnet, "replica").id,
          synchronization_status: "ready", timeline_access: "fetch", version: "16", is_representative: true,
        )
        expect(replica.replication_parent_server).to eq(postgres_server)
      end
    end

    describe "#replication_child_servers" do
      it "is empty for a non-representative server" do
        expect(standby.replication_child_servers).to eq([])
      end

      it "includes HA standbys and read replica representatives" do
        postgres_server
        standby
        replica_resource = create_postgres_resource(project:, location_id: location.id)
        replica_resource.update(parent_id: resource.id)
        replica = described_class.create(
          timeline:, resource_id: replica_resource.id, vm_id: create_hosted_vm(project, private_subnet, "replica").id,
          synchronization_status: "ready", timeline_access: "fetch", version: "16", is_representative: true,
        )
        expect(postgres_server.replication_child_servers).to contain_exactly(standby, replica)
      end
    end

    it "#restart_sensitive_target_values uses schema defaults unless the user overrides them" do
      expect(postgres_server.restart_sensitive_target_values["max_connections"]).to eq(500)
      resource.update(user_config: {"max_connections" => "200"})
      expect(postgres_server.restart_sensitive_target_values["max_connections"]).to eq(200)
    end

    describe "#restart_sensitive_running_values" do
      it "parses the queried settings" do
        expect(postgres_server.vm.sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_return(running_csv([500, 8, 10, 0, 64]))
        expect(postgres_server.restart_sensitive_running_values).to eq(running([500, 8, 10, 0, 64]))
      end

      it "returns nil when a parameter is missing" do
        expect(postgres_server.vm.sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_return("max_connections,500")
        expect(postgres_server.restart_sensitive_running_values).to be_nil
      end

      it "returns nil when the query times out" do
        expect(postgres_server.vm.sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_raise(Sshable::SshTimeout.new("boom", "", "", nil, nil))
        expect(postgres_server.restart_sensitive_running_values).to be_nil
      end

      it "returns nil when postgres is not accepting connections" do
        expect(postgres_server.vm.sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_raise(Sshable::SshError.new(psql_command, "", "connection refused", 2, nil))
        expect(postgres_server.restart_sensitive_running_values).to be_nil
      end
    end

    describe "#restart_sensitive_params_safe?" do
      it "is safe for a standalone primary with no neighbours" do
        expect(postgres_server.restart_sensitive_params_safe?).to be true
      end

      it "blocks a standby decrease until the primary has the lower value" do
        postgres_server
        resource.update(user_config: {"max_connections" => "200"})
        primary_sshable = standby.replication_parent_server.vm.sshable
        expect(primary_sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_return(running_csv([500, 8, 10, 0, 64]))
        expect(standby.restart_sensitive_params_safe?).to be false
      end

      it "allows a standby decrease once the primary already has the lower value" do
        postgres_server
        resource.update(user_config: {"max_connections" => "200"})
        primary_sshable = standby.replication_parent_server.vm.sshable
        expect(primary_sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_return(running_csv([200, 8, 10, 0, 64]))
        expect(standby.restart_sensitive_params_safe?).to be true
      end

      it "blocks a primary increase until the standby has the higher value" do
        standby
        resource.update(user_config: {"max_connections" => "800"})
        child_sshable = postgres_server.replication_child_servers.first.vm.sshable
        expect(child_sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_return(running_csv([500, 8, 10, 0, 64]))
        expect(postgres_server.restart_sensitive_params_safe?).to be false
      end

      it "allows a primary increase once the standby already has the higher value" do
        standby
        resource.update(user_config: {"max_connections" => "800"})
        child_sshable = postgres_server.replication_child_servers.first.vm.sshable
        expect(child_sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_return(running_csv([800, 8, 10, 0, 64]))
        expect(postgres_server.restart_sensitive_params_safe?).to be true
      end

      it "skips neighbours whose running values cannot be read" do
        standby
        resource.update(user_config: {"max_connections" => "800"})
        child_sshable = postgres_server.replication_child_servers.first.vm.sshable
        expect(child_sshable).to receive(:_cmd).with(psql_command, stdin: settings_query).and_raise(Sshable::SshTimeout.new("boom", "", "", nil, nil))
        expect(postgres_server.restart_sensitive_params_safe?).to be true
      end
    end
  end

  describe "#user_config" do
    it "bounds ubicloud.shared_memory_percent against the VM this server actually runs on" do
      # A scale up to 32 GiB may have been requested, so the stored 75 can be
      # valid for target_vm_size while this server is still on a smaller VM.
      resource.update(user_config: {"ubicloud.shared_memory_percent" => "75"})
      percents = [8, 16, 32].map do |memory_gib|
        postgres_server.vm.update(memory_gib:)
        postgres_server.user_config["ubicloud.shared_memory_percent"]
      end
      expect(percents).to eq ["50", "50", "75"]
    end

    it "leaves the config untouched when the percent is unset" do
      resource.update(user_config: {"work_mem" => "32MB"})
      expect(postgres_server.user_config).to eq({"work_mem" => "32MB"})
    end
  end

  describe "#trigger_failover" do
    it "logs error when server is not representative" do
      postgres_server.update(is_representative: false)
      expect(Clog).to receive(:emit).with("Cannot trigger failover on a non-representative server", {ubid: postgres_server.ubid}).and_call_original
      expect(postgres_server.trigger_failover(mode: "planned")).to be false
    end

    it "logs error when no suitable standby found" do
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
      expect(Clog).to receive(:emit).with("No suitable standby found for failover", {ubid: postgres_server.ubid}).and_call_original
      expect(postgres_server.trigger_failover(mode: "planned")).to be false
    end

    it "requests a take over from the failover target, with a timeline switch on promote when switch_timeline is set" do
      standby = described_class.create(
        timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "standby").id,
        synchronization_status: "ready", timeline_access: "fetch", version: "16",
      )
      Strand.create_with_id(standby, prog: "Postgres::PostgresServerNexus", label: "wait")
      expect(postgres_server).to receive(:failover_target).with(mode: "planned").and_return(standby).twice
      expect(postgres_server.trigger_failover(mode: "planned")).to be true
      expect(standby.semaphores_dataset.select_order_map(:name)).to eq ["planned_take_over"]
      expect(postgres_server.trigger_failover(mode: "planned", switch_timeline: true)).to be true
      expect(standby.semaphores_dataset.select_order_map(:name)).to eq ["planned_take_over", "planned_take_over", "switch_timeline_on_promote"]
    end
  end

  it "#read_replica? is true when the resource is a read replica" do
    expect(postgres_server).not_to be_read_replica
    resource.update(parent_id: create_postgres_resource(project:, location_id: location.id).id)
    expect(postgres_server).to be_read_replica
  end

  describe "#fallback_active?" do
    before { Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait") }

    it "is false when the ignore_instance_size_mismatch semaphore is not set" do
      expect(postgres_server).not_to be_fallback_active
    end

    it "is true when the ignore_instance_size_mismatch semaphore is set" do
      postgres_server.incr_ignore_instance_size_mismatch
      expect(postgres_server).to be_fallback_active
    end
  end

  describe "#fallback_eligible?" do
    before { Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait") }

    it "is false when the vm is not on AWS" do
      project.set_ff_postgres_instance_type_fallback(true)
      expect(postgres_server).not_to be_fallback_eligible
    end

    it "is true on AWS only when the project feature flag is on" do
      location.update(provider: "aws")
      expect(postgres_server).not_to be_fallback_eligible
      project.set_ff_postgres_instance_type_fallback(true)
      expect(postgres_server).to be_fallback_eligible
    end

    it "is false when recycle_by_user_request is set" do
      location.update(provider: "aws")
      project.set_ff_postgres_instance_type_fallback(true)
      postgres_server.incr_recycle_by_user_request
      expect(postgres_server).not_to be_fallback_eligible
    end
  end

  describe "#needs_recycling?" do
    before do
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
      VmStorageVolume.create(vm:, disk_index: 0, boot: false, size_gib: resource.target_storage_size_gib)
      resource.update(target_version: postgres_server.version)
    end

    it "recycles on instance size mismatch when ignore_instance_size_mismatch is not set" do
      expect(postgres_server.needs_recycling?).to be false
      resource.update(target_vm_size: "standard-4")
      expect(postgres_server.needs_recycling?).to be true
    end

    it "does not recycle on instance size mismatch when ignore_instance_size_mismatch is set" do
      postgres_server.incr_ignore_instance_size_mismatch
      resource.update(target_vm_size: "standard-4")
      expect(postgres_server.needs_recycling?).to be false
      resource.update(target_storage_size_gib: 128)
      expect(postgres_server.needs_recycling?).to be true
    end

    it "translates burstable to hobby when comparing vm.display_size to resource.target_vm_size" do
      vm.update(family: "burstable", cpu_percent_limit: 100)
      resource.update(target_vm_size: "hobby-2")
      expect(postgres_server.needs_recycling?).to be false
    end

    it "recycles when the image family does not match the resource's target" do
      resource.update(target_image_family: "ubuntu-2604")
      expect(postgres_server.needs_recycling?).to be true
    end
  end

  describe "#failover_target" do
    let(:lsn_command) { "PGOPTIONS='-c statement_timeout=60s' psql -U ubi_monitoring -d ubi_admin -t --csv -v 'ON_ERROR_STOP=1'" }
    let(:lsns) { {} }

    before do
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
      resource.update(target_version: postgres_server.version)
    end

    def create_standby(name, lsn: nil, label: "wait", slot_ready: true, family: "standard")
      standby_vm = create_hosted_vm(project, private_subnet, name)
      standby_vm.update(family:)
      VmStorageVolume.create(vm: standby_vm, disk_index: 0, boot: false, size_gib: resource.target_storage_size_gib)
      standby = described_class.create(
        timeline:, resource:, vm_id: standby_vm.id, synchronization_status: "ready", timeline_access: "fetch",
        version: postgres_server.version, physical_slot_ready_id: (postgres_server.id if slot_ready),
      )
      Strand.create_with_id(standby, prog: "Postgres::PostgresServerNexus", label:)
      lsns[standby.id] = lsn if lsn
      standby
    end

    # Only standbys created with an lsn are expected to be asked for their
    # current lsn, which runs over SSH.
    def failover_target(mode: "unplanned")
      resource.servers(reload: true).each do |server|
        next unless (lsn = lsns[server.id])
        expect(server.vm.sshable).to receive(:_cmd).with(lsn_command, stdin: DB.select(server.last_lsn_expression).no_auto_parameterize.sql).and_return("#{lsn}\n")
      end
      postgres_server.failover_target(mode:)&.ubid
    end

    it "returns nil if there is no standby" do
      expect(failover_target).to be_nil
    end

    it "returns the standby with highest lsn among standbys at wait" do
      create_standby("catching-up", label: "wait_catch_up")
      create_standby("low-lsn", lsn: "1/5")
      high = create_standby("high-lsn", lsn: "1/10")
      expect(failover_target).to eq(high.ubid)
    end

    it "returns nil for planned failover if there is no fresh standby" do
      create_standby("standby")
      resource.update(target_vm_size: "standard-4")
      expect(failover_target(mode: "planned")).to be_nil
    end

    it "returns nil for planned failover when no standby has physical_slot_ready" do
      create_standby("standby", slot_ready: false)
      expect(Clog).to receive(:emit).with("Planned failover waiting for physical slot ready", {ubid: postgres_server.ubid, standby_count: 1}).and_call_original
      expect(failover_target(mode: "planned")).to be_nil
    end

    it "prefers a standby with physical_slot_ready_id set, but falls back to one without for unplanned failover" do
      without_slot = create_standby("without-slot", lsn: "1/10", slot_ready: false)
      expect(failover_target).to eq(without_slot.ubid)
      with_slot = create_standby("with-slot", lsn: "1/5")
      expect(failover_target).to eq(with_slot.ubid)
    end

    it "considers a standby needing recycling only for unplanned failover" do
      standby = create_standby("recycling", lsn: "1/10")
      standby.incr_recycle
      expect(failover_target).to eq(standby.ubid)
      lsns.clear
      expect(failover_target(mode: "planned")).to be_nil
    end

    it "returns the standby for planned failover only when its logical slots are synced" do
      standby = create_standby("standby", lsn: "1/10")
      expect(postgres_server).to receive(:unsynced_logical_failover_slots).with(having_attributes(id: standby.id)).and_return(["slot1"], [])
      expect(Clog).to receive(:emit).with("Planned failover waiting for logical slot sync", {ubid: postgres_server.ubid, standby: standby.ubid, missing_slots: ["slot1"]}).and_call_original
      expect(failover_target(mode: "planned")).to be_nil
      expect(failover_target(mode: "planned")).to eq(standby.ubid)
    end

    it "returns nil for async replication when last_known_lsn is unknown or too far behind" do
      resource.update(ha_type: PostgresResource::HaType::ASYNC)
      standby = create_standby("standby", lsn: "1/10")
      expect(failover_target).to be_nil

      postgres_server.update_last_known_lsn("2/0")
      expect(failover_target).to be_nil

      postgres_server.update_last_known_lsn("1/11")
      expect(failover_target).to eq(standby.ubid)
    ensure
      # POSTGRES_MONITOR_DB doesn't use transactional testing, so it must be manually cleaned up
      postgres_server.lsn_monitor_ds.delete
    end

    it "prefers higher lsn over intended-type when both slot-ready" do
      fallback = create_standby("fallback-high-lsn", lsn: "1/10", family: "r6id")
      fallback.incr_ignore_instance_size_mismatch
      create_standby("intended-low-lsn", lsn: "1/5", family: "r8id")
      expect(failover_target).to eq(fallback.ubid)
    end

    it "prefers intended-type over family rank at equal lsn" do
      resource.update(target_vm_size: "r6id.large")
      intended = create_standby("intended-old", lsn: "1/10", family: "r6id")
      create_standby("fallback-new", lsn: "1/10", family: "r8id").incr_ignore_instance_size_mismatch
      expect(failover_target).to eq(intended.ubid)
    end

    it "prefers newer family rank as final tiebreaker at equal lsn and intended-type" do
      newer = create_standby("newer-family", lsn: "1/10", family: "r8id")
      create_standby("older-family", lsn: "1/10", family: "r6id")
      expect(failover_target).to eq(newer.ubid)
    end

    describe "for a read replica" do
      before { resource.update(parent_id: create_postgres_resource(project:, location_id: location.id).id) }

      it "returns the replica with highest lsn for planned failover even if physical_slot_ready_id is nil" do
        create_standby("low-lsn", lsn: "1/5", slot_ready: false)
        high = create_standby("high-lsn", lsn: "1/10", slot_ready: false)
        expect(failover_target(mode: "planned")).to eq(high.ubid)
      end

      it "returns nil for planned failover if there is no fresh read replica" do
        create_standby("replica", slot_ready: false)
        resource.update(target_vm_size: "standard-4")
        expect(failover_target(mode: "planned")).to be_nil
      end
    end
  end

  describe "#unsynced_logical_failover_slots" do
    let(:standby) {
      described_class.create(
        timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "standby").id,
        synchronization_status: "ready", timeline_access: "fetch", version: "16",
      )
    }
    let(:monitoring_psql_command) { "PGOPTIONS='-c statement_timeout=60s' psql -U ubi_monitoring -d ubi_admin -t --csv -v 'ON_ERROR_STOP=1'" }

    it "returns empty for versions below 17 and for read replicas" do
      expect(postgres_server.unsynced_logical_failover_slots(standby)).to eq []
      postgres_server.update(version: "17")
      resource.update(parent_id: create_postgres_resource(project:, location_id: location.id).id)
      expect(postgres_server.unsynced_logical_failover_slots(standby)).to eq []
    end

    it "returns empty when primary is fenced (avoids querying a stopped server)" do
      postgres_server.update(version: "17")
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait_in_fence")
      expect(postgres_server.vm.sshable).not_to receive(:_cmd)
      expect(postgres_server.unsynced_logical_failover_slots(standby)).to eq []
    end

    it "returns the primary's logical failover slots that are missing or lagging on the standby" do
      postgres_server.update(version: "17")
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with(monitoring_psql_command, stdin: a_string_including("AND failover"))
        .and_return("", "slot1,0/100\nslot2,0/200", "slot1,0/100\nslot2,0/200", "slot1,0/200")
      expect(standby.vm.sshable).to receive(:_cmd).with(monitoring_psql_command, stdin: a_string_including("synced AND NOT temporary"))
        .and_return("slot1,0/100\nslot2,0/200", "slot1,0/100", "slot1,0/100")
      expect(Array.new(4) { postgres_server.unsynced_logical_failover_slots(standby) }).to eq [[], [], ["slot2"], ["slot1"]]
    end
  end

  it "#storage_size_gib sums the sizes of the non-boot volumes" do
    expect(postgres_server.storage_size_gib).to eq 0
    VmStorageVolume.create(vm:, disk_index: 0, boot: true, size_gib: 20)
    VmStorageVolume.create(vm:, disk_index: 1, boot: false, size_gib: 64)
    postgres_server.vm.vm_storage_volumes(reload: true)
    expect(postgres_server.storage_size_gib).to eq 64
  end

  describe "#lsn_caught_up" do
    let(:parent_server) {
      described_class.create(
        timeline:, resource: create_postgres_resource(project:, location_id: location.id), vm_id: create_hosted_vm(project, private_subnet, "parent-vm").id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16",
      )
    }

    before do
      resource.update(parent: parent_server.resource)
      postgres_server.update(timeline_access: "fetch")
    end

    after do
      # POSTGRES_MONITOR_DB doesn't use transactional testing, so it must be manually cleaned up
      POSTGRES_MONITOR_DB[:postgres_lsn_monitor].where(postgres_server_id: [postgres_server.id, parent_server.id]).delete
    end

    it "returns true immediately for primary" do
      postgres_server.update(timeline_access: "push")
      expect(postgres_server.lsn_caught_up).to be(true)
    end

    it "returns true if read replica and the parent is nil" do
      resource.update(parent_id: PostgresResource.generate_ubid.to_uuid)
      expect(postgres_server.lsn_caught_up).to be(true)
    end

    it "compares a read replica's lsn with the lsn of the parent's representative server" do
      results = [[nil, nil], ["F/F", nil], ["F/F", "1/00000000"], ["F/F", "F/F"]].map do |parent_lsn, lsn|
        parent_server.update_last_known_lsn(parent_lsn) if parent_lsn
        postgres_server.update_last_known_lsn(lsn) if lsn
        postgres_server.lsn_caught_up
      end
      expect(results).to eq [nil, nil, false, true]
    end

    it "compares with the resource's own representative server when not a read replica" do
      resource.update(restore_target: Time.now)
      postgres_server.update_last_known_lsn("F/F")
      expect(postgres_server.lsn_caught_up).to be(true)
    end

    it "scales the threshold with the parent vm size" do
      parent_server.update_last_known_lsn("1/40000000")
      postgres_server.update_last_known_lsn("1/2D000000")
      parent_vm = resource.parent.representative_server.vm
      postgres_server.vm.update(vcpus: 16)
      parent_vm.update(vcpus: 4)
      expect(postgres_server.lsn_caught_up).to be(false)
      postgres_server.vm.update(vcpus: 2)
      parent_vm.update(vcpus: 8)
      expect(postgres_server.lsn_caught_up).to be(true)
    end
  end

  describe "#catch_up_lag_threshold" do
    it "is 64 MiB per parent vcpu clamped to 128 MiB and 1 GiB" do
      expect([1, 2, 8, 16, 64].map { |vcpus|
        postgres_server.vm.update(vcpus:)
        postgres_server.catch_up_lag_threshold(postgres_server) / 1024 / 1024
      }).to eq([128, 128, 512, 1024, 1024])
    end
  end

  describe "#last_known_lsn" do
    it "returns the value recorded by the monitor" do
      postgres_server.update_last_known_lsn("1/1234")
      expect(postgres_server.last_known_lsn).to eq("1/1234")
      postgres_server.lsn_monitor_ds.delete
    end

    it "returns nil when no pulse has been recorded" do
      expect(postgres_server.last_known_lsn).to be_nil
    end
  end

  describe "#current_lsn" do
    # Stub the ssh layer rather than run_query, which the cmd_exec linter forbids
    # stubbing; last_lsn_expression's branches are covered by their own examples.
    it "runs the recovery-aware lsn query on the server" do
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U ubi_monitoring -d ubi_admin -t --csv -v 'ON_ERROR_STOP=1'", stdin: a_string_including("pg_is_in_recovery")).and_return("1/5\n")
      expect(postgres_server.current_lsn).to eq("1/5")
    end
  end

  describe "#data_disk_usage" do
    it "returns the used 1K blocks reported by df on /dat" do
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("df --output=used /dat | tail -n 1").and_return("1024000\n")
      expect(postgres_server.data_disk_usage).to eq(1024000)
    end

    it "returns 0 when the ssh command fails" do
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("df --output=used /dat | tail -n 1").and_raise(RuntimeError)
      expect(postgres_server.data_disk_usage).to eq(0)
    end

    it "raises when the ssh command fails and raise_on_error is true" do
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("df --output=used /dat | tail -n 1").and_raise(RuntimeError, "boom")
      expect { postgres_server.data_disk_usage(raise_on_error: true) }.to raise_error(RuntimeError, "boom")
    end
  end

  describe "#disk_usage_percent" do
    it "returns the percentage reported by df on /dat" do
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  95%\n")
      expect(postgres_server.disk_usage_percent).to eq(95)
    end

    it "raises when the ssh command fails" do
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_raise(RuntimeError)
      expect { postgres_server.disk_usage_percent }.to raise_error(RuntimeError)
    end
  end

  it "initiates a new health monitor session" do
    forward = instance_double(Net::SSH::Service::Forward)
    expect(forward).to receive(:local_socket)
    session = Net::SSH::Connection::Session.allocate
    expect(session).to receive(:forward).and_return(forward)
    expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(session)
    postgres_server.init_health_monitor_session
    expect(File.stat(postgres_server.health_monitor_socket_path).mode & 0o777).to eq(0o700)
  end

  it "passes hardcoded port and database to Sequel.connect when opening a fresh db_connection" do
    db = instance_double(Sequel::Postgres::Database)
    expect(Sequel).to receive(:connect).with(
      hash_including(host: postgres_server.health_monitor_socket_path, port: 5432, database: "ubi_admin", user: "ubi_monitoring"),
    ).and_return(db)
    expect(db).to receive(:get).and_raise(Sequel::DatabaseConnectionError)

    session = {ssh_session: Net::SSH::Connection::Session.allocate, db_connection: nil}
    pulse = {reading: "down", reading_rpt: 1, reading_chg: Time.now}
    postgres_server.check_pulse(session:, previous_pulse: pulse)
  end

  it "initiates a new metrics export session" do
    session = Net::SSH::Connection::Session.allocate
    expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(session)
    postgres_server.init_metrics_export_session
  end

  it "checks pulse" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate,
      db_connection: DB,
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30,
    }

    expect(postgres_server).not_to receive(:incr_checkup)

    postgres_server.check_pulse(session:, previous_pulse: pulse)
  end

  it "asks configure to heal when the denial crosses the detection threshold" do
    session = {ssh_session: Net::SSH::Connection::Session.allocate, db_connection: instance_double(Sequel::Postgres::Database)}
    pulse = {reading: "down", reading_rpt: 5, reading_chg: Time.now}
    Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")

    expect(session[:db_connection]).to receive(:get).and_raise(Sequel::DatabaseConnectionError, 'FATAL:  permission denied for database "ubi_admin"')
    expect(Prog::PageNexus).not_to receive(:assemble)

    postgres_server.check_pulse(session:, previous_pulse: pulse)

    expect(Semaphore.where(strand_id: postgres_server.id, name: "configure").count).to eq(1)
  end

  it "neither heals nor pages for a standby, whose denial replicates from the primary" do
    postgres_server
    standby = described_class.create(timeline:, resource:, is_representative: false, synchronization_status: "ready", timeline_access: "fetch", version: "16")
    Strand.create_with_id(standby, prog: "Postgres::PostgresServerNexus", label: "wait")
    session = {ssh_session: Net::SSH::Connection::Session.allocate, db_connection: instance_double(Sequel::Postgres::Database)}
    pulse = {reading: "down", reading_rpt: 5, reading_chg: Time.now - 6 * 60}

    expect(session[:db_connection]).to receive(:get).and_raise(Sequel::DatabaseConnectionError, 'FATAL:  permission denied for database "ubi_admin"')
    expect(Prog::PageNexus).not_to receive(:assemble)

    standby.check_pulse(session:, previous_pulse: pulse)

    expect(Semaphore.where(name: "configure")).to be_empty
  end

  it "pages when the denial outlasts the heal window" do
    session = {ssh_session: Net::SSH::Connection::Session.allocate, db_connection: instance_double(Sequel::Postgres::Database)}
    pulse = {reading: "down", reading_rpt: 6, reading_chg: Time.now - 6 * 60}

    expect(session[:db_connection]).to receive(:get).and_raise(Sequel::DatabaseConnectionError, 'FATAL:  permission denied for database "ubi_admin"')

    postgres_server.check_pulse(session:, previous_pulse: pulse)

    page = Page.from_tag_parts("PGMonitoringAccessDenied", postgres_server.id)
    expect(page.summary).to eq("Postgres monitoring lost its database privileges")
    expect(page.severity).to eq("error")
    expect(page.details["related_resources"]).to eq([postgres_server.ubid])
    expect(page.resource_id).to eq(postgres_server.id)
    expect(page.resource_id).to eq(postgres_server.id)
  end

  it "waits for the heal window before paging" do
    session = {ssh_session: Net::SSH::Connection::Session.allocate, db_connection: instance_double(Sequel::Postgres::Database)}
    pulse = {reading: "down", reading_rpt: 6, reading_chg: Time.now}
    Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")

    expect(session[:db_connection]).to receive(:get).and_raise(Sequel::DatabaseConnectionError, 'FATAL:  permission denied for database "ubi_admin"')
    expect(Prog::PageNexus).not_to receive(:assemble)

    postgres_server.check_pulse(session:, previous_pulse: pulse)

    expect(Semaphore.where(strand_id: postgres_server.id, name: "configure")).to be_empty
  end

  it "does not page when the pulse is down for an ordinary reason" do
    session = {ssh_session: Net::SSH::Connection::Session.allocate, db_connection: instance_double(Sequel::Postgres::Database)}
    pulse = {reading: "down", reading_rpt: 5, reading_chg: Time.now}

    expect(session[:db_connection]).to receive(:get).and_raise(Sequel::DatabaseConnectionError, "could not connect to server")
    expect(Prog::PageNexus).not_to receive(:assemble)

    postgres_server.check_pulse(session:, previous_pulse: pulse)
  end

  it "resolves the privilege page once the pulse reads up again" do
    page = instance_double(Page)
    expect(Page).to receive(:from_tag_parts).with("PGMonitoringAccessDenied", postgres_server.id).and_return(page)
    expect(page).to receive(:incr_resolve)

    postgres_server.check_pulse(session: {db_connection: DB}, previous_pulse: {})
  end

  it "increments checkup semaphore if pulse is down for a while and the resource is not upgrading" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate,
      db_connection: instance_double(Sequel::Postgres::Database),
    }
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: Time.now - 30,
    }

    expect(session[:db_connection]).to receive(:get).and_raise(Sequel::DatabaseConnectionError)
    expect(postgres_server).to receive(:reload).and_return(postgres_server)
    expect(postgres_server).to receive(:incr_checkup)
    Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
    postgres_server.check_pulse(session:, previous_pulse: pulse)
  end

  it "queries the recovery-aware lsn expression" do
    session = {
      ssh_session: Net::SSH::Connection::Session.allocate,
      db_connection: instance_double(Sequel::Postgres::Database),
    }
    pulse = {reading: "up", reading_rpt: 1, reading_chg: Time.now}

    expect(session[:db_connection]).to receive(:get).with(postgres_server.last_lsn_expression.as(:lsn)).and_return("1/5")
    expect(postgres_server.check_pulse(session:, previous_pulse: pulse)[:reading]).to eq("up")
  end

  # The not-in-recovery branch is pg_current_wal_lsn regardless of the cached
  # role, so a promoted server carrying a stale "standby" role uses its write
  # position, not a frozen pg_last_wal_receive_lsn.
  it "uses pg_last_wal_receive_lsn for a streaming standby, and pg_last_wal_replay_lsn while it is catching up" do
    postgres_server
    standby = described_class.create(
      timeline:, resource:, vm_id: create_hosted_vm(project, private_subnet, "standby").id,
      synchronization_status: "ready", timeline_access: "fetch", version: "16",
    )
    strand = Strand.create_with_id(standby, prog: "Postgres::PostgresServerNexus", label: "wait")
    expect(DB.literal(standby.last_lsn_expression)).to eq("(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_receive_lsn() ELSE pg_current_wal_lsn() END)")
    strand.update(label: "wait_catch_up")
    standby.strand(reload: true)
    expect(DB.literal(standby.last_lsn_expression)).to eq("(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END)")
  end

  it "uses pg_last_wal_replay_lsn for a read replica or pitr server" do
    # Read replicas and PITR are in recovery but not standby?, so they track
    # replayed WAL, not received.
    postgres_server.update(timeline_access: "fetch")
    expect(DB.literal(postgres_server.last_lsn_expression)).to eq("(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END)")
  end

  describe "lsn persistence during catch up" do
    let(:standby) {
      described_class.create(timeline:, resource:, is_representative: false, synchronization_status: "catching_up", timeline_access: "fetch", version: "16")
    }
    let(:session) { {db_connection: instance_double(Sequel::Postgres::Database)} }

    after { postgres_server.lsn_monitor_ds.delete }

    def pulse_twice
      expect(session[:db_connection]).to receive(:get).and_return("1/5", "1/6")
      pulse = postgres_server.check_pulse(session:, previous_pulse: {})
      expect(pulse[:reading_rpt]).to eq(1)
      expect(postgres_server.check_pulse(session:, previous_pulse: pulse)[:reading_rpt]).to eq(2)
    end

    it "persists every pulse while a standby of the resource is catching up" do
      Strand.create_with_id(standby, prog: "Postgres::PostgresServerNexus", label: "wait_catch_up")
      pulse_twice
      expect(session[:lsn_catch_up_in_progress]).to be(true)
      expect(postgres_server.last_known_lsn).to eq("1/6")
    end

    it "persists once a minute when no catch up is in progress" do
      Strand.create_with_id(standby, prog: "Postgres::PostgresServerNexus", label: "wait")
      pulse_twice
      expect(session[:lsn_catch_up_in_progress]).to be(false)
      expect(postgres_server.last_known_lsn).to eq("1/5")
    end

    it "does not count servers of unrelated resources" do
      other = described_class.create(timeline:, resource: create_postgres_resource(project:, location_id: location.id), is_representative: false, synchronization_status: "catching_up", timeline_access: "fetch", version: "16")
      Strand.create_with_id(other, prog: "Postgres::PostgresServerNexus", label: "wait_catch_up")
      expect(postgres_server.lsn_catch_up_in_progress?).to be(false)
    end
  end

  it "catches Sequel::Error if updating last known lsn fails" do
    expect(Clog).to receive(:emit).with("Failed to update last known lsn", instance_of(Hash)).and_call_original
    expect(postgres_server).to receive(:update_last_known_lsn).and_raise(Sequel::Error)
    postgres_server.check_pulse(session: {db_connection: DB}, previous_pulse: {})
  end

  it "runs query on vm" do
    expect(postgres_server.vm.sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -d postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: "SELECT 1").and_return("1\n")
    expect(postgres_server.run_query("SELECT 1")).to eq("1")
  end

  it "runs query with a custom statement timeout" do
    expect(postgres_server.vm.sshable).to receive(:_cmd).with("PGOPTIONS=-c\\ statement_timeout\\=5s psql -U postgres -d postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: "SELECT 1").and_return("1\n")
    expect(postgres_server.run_query("SELECT 1", statement_timeout: 5)).to eq("1")
  end

  it "runs query over a provided ssh session" do
    session = Net::SSH::Connection::Session.allocate
    expect(postgres_server.vm.sshable).to receive(:_cmd).with("PGOPTIONS='-c statement_timeout=60s' psql -U postgres -d postgres -t --csv -v 'ON_ERROR_STOP=1'", stdin: "SELECT 1", session:).and_return("1\n")
    expect(postgres_server.run_query("SELECT 1", session:)).to eq("1")
  end

  it "returns the right storage_device_paths for AWS" do
    location.update(provider: "aws")
    expect(postgres_server.vm.sshable).to receive(:_cmd).with("lsblk -b -d -n -e 7 -o NAME,SIZE | sort -n -k2 | tail -n +2 | awk '{print \"/dev/\"$1}'").and_return("/dev/nvme1n1\n/dev/nvme2n1\n")
    expect(postgres_server.storage_device_paths).to eq(["/dev/nvme1n1", "/dev/nvme2n1"])
  end

  it "uses the default open_session_failure_page_threshold for AWS" do
    location.update(provider: "aws")
    expect(postgres_server.open_session_failure_page_threshold).to eq(MonitorableResource::OPEN_SESSION_FAILURE_PAGE_THRESHOLD)
  end

  it "returns the right storage_device_paths for Hetzner" do
    VmStorageVolume.create(vm:, disk_index: 0, boot: true, size_gib: 64)
    vsv = VmStorageVolume.create(vm:, disk_index: 1, boot: false, size_gib: 1024)
    expect(postgres_server.storage_device_paths).to eq([vsv.device_path])
  end

  it "#provider_dispatcher_group_name delegates to resource location, falling back to the vm's when the resource row is deleted" do
    expect(postgres_server.provider_dispatcher_group_name).to eq("metal")

    PostgresResource.dataset.where(id: resource.id).delete(force: true)
    postgres_server.refresh
    expect(postgres_server.provider_dispatcher_group_name).to eq("metal")
  end

  it "#aws? delegates to location" do
    expect(postgres_server.aws?).to be(false)
  end

  it "#taking_over? is true while the strand is taking over or backfilling the WAL archive" do
    strand = Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
    expect(%w[taking_over backfill_wal_archive wait].map { |label|
      strand.update(label:)
      postgres_server.strand(reload: true)
      postgres_server.taking_over?
    }).to eq [true, true, false]
  end

  describe "#switch_to_new_timeline" do
    it "switches to a new push timeline, whose parent is the current timeline unless given" do
      previous_timeline = postgres_server.timeline
      postgres_server.update(timeline_access: "fetch", synchronization_status: "catching_up")
      expect(postgres_server).to receive(:detach_s3_policy).with(previous_timeline).and_call_original
      postgres_server.switch_to_new_timeline
      new_timeline = postgres_server.timeline
      expect([new_timeline.parent_id, postgres_server.timeline_access, postgres_server.synchronization_status]).to eq [previous_timeline.id, "push", "ready"]

      expect(postgres_server).to receive(:detach_s3_policy).with(new_timeline).and_call_original
      postgres_server.switch_to_new_timeline(parent_id: nil)
      expect(postgres_server.timeline.id).not_to eq new_timeline.id
      expect(postgres_server.timeline.parent_id).to be_nil
    end

    it "stops wal-g and configures the new timeline on AWS" do
      location.update(provider: "aws")
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl stop wal-g")
      expect(postgres_server).to receive(:refresh_walg_credentials)
      postgres_server.switch_to_new_timeline
      expect(postgres_server.semaphores_dataset.select_map(:name)).to eq ["configure_s3_new_timeline"]
    end
  end

  describe "#refresh_walg_credentials" do
    it "does nothing if timeline has no blob storage" do
      expect(postgres_server.timeline.blob_storage).to be_nil
      expect(vm.sshable).not_to receive(:_cmd)
      postgres_server.refresh_walg_credentials
    end

    it "refreshes walg credentials if timeline has blob storage not on aws" do
      expect(timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, root_certs: "root_certs")).at_least(:once)
      expect(timeline).to receive(:generate_walg_config).with(postgres_server.version, postgres_server).and_return("walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo tee /usr/lib/ssl/certs/blob_storage_ca.crt > /dev/null", stdin: "root_certs")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo mkdir -p /etc/systemd/system/wal-g.service.d")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/wal-g.service.d/stop-timeout.conf > /dev/null", stdin: "[Service]\nTimeoutStopSec=5s\n")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl restart wal-g")
      postgres_server.refresh_walg_credentials
    end

    it "refreshes walg credentials without the blob storage CA if timeline has blob storage on aws" do
      location.update(provider: "aws")
      expect(timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster, root_certs: "root_certs")).at_least(:once)
      expect(timeline).to receive(:generate_walg_config).with(postgres_server.version, postgres_server).and_return("walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres tee /etc/postgresql/wal-g.env > /dev/null", stdin: "walg_config")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo mkdir -p /etc/systemd/system/wal-g.service.d")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/wal-g.service.d/stop-timeout.conf > /dev/null", stdin: "[Service]\nTimeoutStopSec=5s\n")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo systemctl restart wal-g")
      postgres_server.refresh_walg_credentials
    end
  end

  describe "#walg_credentials_ready?" do
    it "returns true without ssh when timeline has no blob storage" do
      expect(postgres_server.timeline.blob_storage).to be_nil
      expect(postgres_server.vm.sshable).not_to receive(:_cmd)
      expect(postgres_server.walg_credentials_ready?).to be true
    end

    it "runs wal-g st check read and returns true on success" do
      expect(timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster))
      expect(postgres_server.vm.sshable).to receive(:_cmd).with("sudo -u postgres /usr/bin/wal-g st check read --config /etc/postgresql/wal-g.env")
      expect(postgres_server.walg_credentials_ready?).to be true
    end

    it "returns false when ssh check raises" do
      expect(timeline).to receive(:blob_storage).and_return(instance_double(MinioCluster))
      expect(postgres_server.vm.sshable).to receive(:_cmd).and_raise(Sshable::SshError.new("cmd", "", "denied", 1, nil))
      expect(postgres_server.walg_credentials_ready?).to be false
    end
  end

  describe "#install_rhizome" do
    it "has a shortcut to install Rhizome" do
      st = postgres_server.install_rhizome
      expect(st.prog).to eq("InstallRhizome")
      expect(st.stack).to eq(["subject_id" => postgres_server.vm.id, "target_folder" => "postgres"])
    end
  end

  describe "#export_metrics" do
    let(:session) { {ssh_session: Net::SSH::Connection::Session.allocate} }
    let(:tsdb_client) { instance_double(VictoriaMetrics::Client) }

    it "counts exports in the session and calls the observe methods on the first of every 12 exports" do
      expect(postgres_server).to receive(:scrape_endpoints).and_return([]).exactly(13).times
      %i[observe_data_disk_usage observe_root_disk_usage observe_archival_backlog observe_io_throttle observe_metrics_backlog observe_replica_lag].each do |method|
        expect(postgres_server).to receive(method).with(session).twice
      end

      13.times { postgres_server.export_metrics(session:, tsdb_client:) }
      expect(session[:export_count]).to eq(13)
    end
  end

  describe "#observe_archival_backlog" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    before do
      allow(postgres_server).to receive(:archival_backlog_threshold).and_return(10)
    end

    def expect_archive_status(oldest_pending, backlog)
      expect(session[:ssh_session]).to receive(:_exec!).with("sudo -u postgres find /dat/16/data/pg_wal/archive_status -name '*.ready' -printf '%f\\n' | sort | head -1").and_return("#{oldest_pending}\n")
      expect(session[:ssh_session]).to receive(:_exec!).with("sudo find /dat/16/data/pg_wal/archive_status -name '*.ready' | wc -l").and_return("#{backlog}\n")
    end

    def page
      Page.from_tag_parts("PGArchivalBacklogHigh", postgres_server.id)
    end

    def create_page
      Prog::PageNexus.assemble(
        "#{postgres_server.ubid} archival backlog high",
        ["PGArchivalBacklogHigh", postgres_server.id],
        postgres_server.ubid,
        resource_id: postgres_server.id,
        severity: "warning",
        extra_data: {archival_backlog: 30},
      ).subject
    end

    it "checks archival backlog and does nothing if it is within limits" do
      expect_archive_status("000000010000000000000005.ready", 5)
      postgres_server.observe_archival_backlog(session)
      expect(page).to be_nil
      expect(session[:previous_oldest_pending_wal]).to eq("000000010000000000000005.ready")
    end

    it "checks archival backlog and creates a page if it is outside of limits with no previous data" do
      expect_archive_status("000000010000000000000010.ready", 15)
      postgres_server.observe_archival_backlog(session)
      expect([page.summary, page.severity, page.details, page.resource_id]).to eq [
        "#{postgres_server.ubid} archival backlog high", "warning",
        {"archival_backlog" => 15, "disk_usage_percent" => 0, "related_resources" => [postgres_server.ubid]},
        postgres_server.id,
      ]
    end

    it "pages with no previous data when no ready files exist" do
      expect_archive_status("", 15)
      postgres_server.observe_archival_backlog(session)
      expect(session[:previous_oldest_pending_wal]).to be_nil
      expect(page).not_to be_nil
    end

    it "does not page when backlog is moderate and upload rate is above threshold" do
      # Previous: segment 5, now: segment 10 (5 segments = 80MB archived)
      # With 1 second elapsed, rate = 80 MB/s > 50 MB/s threshold
      session[:previous_oldest_pending_wal] = "000000010000000000000005.ready"
      session[:previous_archival_check_time] = Time.now - 1
      expect_archive_status("00000001000000000000000A.ready", 15)
      postgres_server.observe_archival_backlog(session)
      expect(page).to be_nil
    end

    it "pages when backlog is moderate but upload rate is below threshold" do
      # Previous: segment 5, now: segment 6 (1 segment = 16MB archived)
      # With 2 seconds elapsed, rate = 8 MB/s < 10 MB/s threshold
      session[:previous_oldest_pending_wal] = "000000010000000000000005.ready"
      session[:previous_archival_check_time] = Time.now - 2
      expect_archive_status("000000010000000000000006.ready", 15)
      postgres_server.observe_archival_backlog(session)
      expect(page).not_to be_nil
    end

    it "pages when backlog is severe regardless of upload rate" do
      session[:previous_oldest_pending_wal] = "000000010000000000000010.ready"
      session[:previous_archival_check_time] = Time.now - 1
      expect_archive_status("000000010000000000000020.ready", 25)
      postgres_server.observe_archival_backlog(session)
      expect(page).not_to be_nil
    end

    it "escalates severity to error when disk usage is high" do
      session[:disk_usage_percent] = 90
      expect_archive_status("000000010000000000000010.ready", 15)
      postgres_server.observe_archival_backlog(session)
      expect([page.severity, page.details["disk_usage_percent"]]).to eq ["error", 90]
    end

    it "resolves a page only once the backlog is below 80% of the threshold (hysteresis)" do
      existing_page = create_page
      expect_archive_status("000000010000000000000009.ready", 9)
      postgres_server.observe_archival_backlog(session)
      expect(existing_page.semaphores_dataset.select_map(:name)).to eq []

      expect_archive_status("000000010000000000000003.ready", 3)
      postgres_server.observe_archival_backlog(session)
      expect(existing_page.semaphores_dataset.select_map(:name)).to eq ["resolve"]
    end

    it "logs errors when checking archival backlog fails" do
      expect(session[:ssh_session]).to receive(:_exec!).and_raise(Net::SSH::Exception.new("SSH error"))
      expect(Clog).to receive(:emit).with("Failed to observe archival backlog", instance_of(Hash)).and_call_original
      postgres_server.observe_archival_backlog(session)
    end
  end

  it "#archival_backlog_threshold is 5% of the storage size as WAL file count, capped at 1000" do
    volume = VmStorageVolume.create(vm:, disk_index: 0, boot: false, size_gib: 100)
    expect(postgres_server.archival_backlog_threshold).to eq(320)
    volume.update(size_gib: 1024)
    postgres_server.vm.vm_storage_volumes(reload: true)
    expect(postgres_server.archival_backlog_threshold).to eq(1000)
  end

  it "#should_page_for_archival_backlog? pages for a severe backlog, or a moderate one without a known upload rate above the minimum" do
    expect(postgres_server).to receive(:archival_backlog_threshold).and_return(10).at_least(:once)
    now = Time.now
    expect([
      [25, "00000001000000000000000F.ready", "000000010000000000000005.ready", now - 1],
      [15, "00000001000000000000000F.ready", nil, nil],
      # 5 segments = 80MB in 1 second = 80 MB/s > 50 MB/s
      [15, "00000001000000000000000A.ready", "000000010000000000000005.ready", now - 1],
      # 1 segment = 16MB in 2 seconds = 8 MB/s < 10 MB/s
      [15, "000000010000000000000006.ready", "000000010000000000000005.ready", now - 2],
      [15, "000000010000000000000006.ready", "000000010000000000000005.ready", now],
    ].map { |backlog, current, previous, previous_time|
      postgres_server.should_page_for_archival_backlog?(backlog, current, previous, now, previous_time)
    }).to eq [true, true, false, true, true]
  end

  it "#wal2lsn converts a WAL filename to an LSN" do
    # Segment 5 = 5 * 16MB = 0x5000000, segment 0x10 = 16 * 16MB = 0x10000000
    expect(postgres_server.wal2lsn("000000010000000000000005.ready")).to eq("00000000/5000000")
    expect(postgres_server.wal2lsn("000000010000000000000010.ready")).to eq("00000000/10000000")
  end

  describe "#observe_metrics_backlog" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }
    let(:now) { Time.now.utc.to_i }
    let(:reading) { ->(count, touched_secs_ago: 0, configured_secs_ago: 60 * 60) { "#{now} #{now - configured_secs_ago} #{now - touched_secs_ago} #{count}\n" } }

    before do
      allow(postgres_server).to receive(:metrics_config).and_return({
        metrics_dir: "/home/ubi/postgres/metrics",
        interval: "15s",
      })
    end

    it "checks metrics backlog and does nothing if it is within limits" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "echo $(date +%s) $(stat -c %Y /home/ubi/postgres/metrics/config.json) $(test -d /home/ubi/postgres/metrics/done && stat -c %Y /home/ubi/postgres/metrics/done || echo 0) $(test -d /home/ubi/postgres/metrics/done && ls /home/ubi/postgres/metrics/done | wc -l || echo 0)",
      ).and_return(reading.call(10))

      postgres_server.observe_metrics_backlog(session)

      expect(Page.from_tag_parts("PGMetricsBacklogHigh", postgres_server.id)).to be_nil
    end

    it "checks metrics backlog and creates a page if it exceeds threshold" do
      # 30 files * 15 seconds = 450 > 300 threshold
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "echo $(date +%s) $(stat -c %Y /home/ubi/postgres/metrics/config.json) $(test -d /home/ubi/postgres/metrics/done && stat -c %Y /home/ubi/postgres/metrics/done || echo 0) $(test -d /home/ubi/postgres/metrics/done && ls /home/ubi/postgres/metrics/done | wc -l || echo 0)",
      ).and_return(reading.call(30))

      postgres_server.observe_metrics_backlog(session)

      page = Page.from_tag_parts("PGMetricsBacklogHigh", postgres_server.id)
      expect(page).not_to be_nil
      expect(page.summary).to eq("#{postgres_server.ubid} metrics backlog high")
      expect(page.severity).to eq("warning")
      expect(page.details["metrics_backlog"]).to eq(30)
      expect(page.details["related_resources"]).to eq([postgres_server.ubid])
      expect(page.resource_id).to eq(postgres_server.id)
    end

    it "checks metrics backlog and resolves a page if it is back within limits" do
      Prog::PageNexus.assemble(
        "Metrics backlog high",
        ["PGMetricsBacklogHigh", postgres_server.id],
        postgres_server.ubid,
        resource_id: postgres_server.id,
        severity: "warning",
        extra_data: {metrics_backlog: 30},
      )
      existing_page = Page.from_tag_parts("PGMetricsBacklogHigh", postgres_server.id)
      # 10 files * 15 seconds = 150 < 300 threshold
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "echo $(date +%s) $(stat -c %Y /home/ubi/postgres/metrics/config.json) $(test -d /home/ubi/postgres/metrics/done && stat -c %Y /home/ubi/postgres/metrics/done || echo 0) $(test -d /home/ubi/postgres/metrics/done && ls /home/ubi/postgres/metrics/done | wc -l || echo 0)",
      ).and_return(reading.call(10))

      postgres_server.observe_metrics_backlog(session)

      expect(existing_page.reload.semaphores.map(&:name)).to include("resolve")
    end

    it "pages when the metrics directory is missing" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "echo $(date +%s) $(stat -c %Y /home/ubi/postgres/metrics/config.json) $(test -d /home/ubi/postgres/metrics/done && stat -c %Y /home/ubi/postgres/metrics/done || echo 0) $(test -d /home/ubi/postgres/metrics/done && ls /home/ubi/postgres/metrics/done | wc -l || echo 0)",
      ).and_return("#{now} #{now - 60 * 60} 0 0\n")

      postgres_server.observe_metrics_backlog(session)

      page = Page.from_tag_parts("PGMetricsBacklogHigh", postgres_server.id)
      expect(page.summary).to eq "#{postgres_server.ubid} is not collecting metrics"
      expect(page.resource_id).to eq(postgres_server.id)
    end

    it "pages when the directory has not been written to or drained recently" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "echo $(date +%s) $(stat -c %Y /home/ubi/postgres/metrics/config.json) $(test -d /home/ubi/postgres/metrics/done && stat -c %Y /home/ubi/postgres/metrics/done || echo 0) $(test -d /home/ubi/postgres/metrics/done && ls /home/ubi/postgres/metrics/done | wc -l || echo 0)",
      ).and_return(reading.call(0, touched_secs_ago: 20 * 60))

      postgres_server.observe_metrics_backlog(session)

      page = Page.from_tag_parts("PGMetricsBacklogHigh", postgres_server.id)
      expect(page.summary).to eq "#{postgres_server.ubid} is not collecting metrics"
    end

    it "does not page a target whose metrics were only just configured" do
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "echo $(date +%s) $(stat -c %Y /home/ubi/postgres/metrics/config.json) $(test -d /home/ubi/postgres/metrics/done && stat -c %Y /home/ubi/postgres/metrics/done || echo 0) $(test -d /home/ubi/postgres/metrics/done && ls /home/ubi/postgres/metrics/done | wc -l || echo 0)",
      ).and_return("#{now} #{now - 30} 0 0\n")

      postgres_server.observe_metrics_backlog(session)

      expect(Page.from_tag_parts("PGMetricsBacklogHigh", postgres_server.id)).to be_nil
    end

    it "does not resolve page if it is still high" do
      Prog::PageNexus.assemble(
        "Metrics backlog high",
        ["PGMetricsBacklogHigh", postgres_server.id],
        postgres_server.ubid,
        resource_id: postgres_server.id,
        severity: "warning",
        extra_data: {metrics_backlog: 30},
      )
      existing_page = Page.from_tag_parts("PGMetricsBacklogHigh", postgres_server.id)
      expect(session[:ssh_session]).to receive(:_exec!).with(
        "echo $(date +%s) $(stat -c %Y /home/ubi/postgres/metrics/config.json) $(test -d /home/ubi/postgres/metrics/done && stat -c %Y /home/ubi/postgres/metrics/done || echo 0) $(test -d /home/ubi/postgres/metrics/done && ls /home/ubi/postgres/metrics/done | wc -l || echo 0)",
      ).and_return(reading.call(19))

      postgres_server.observe_metrics_backlog(session)

      expect(existing_page.reload.semaphores.map(&:name)).not_to include("resolve")
    end
  end

  describe "#observe_replica_lag" do
    let(:session) { {} }
    # postgres_server (subject) is the representative primary of `resource`;
    # `standby` is a non-representative standby of the same resource. LSN values
    # below assume primary at "10/00000000": soft limit 1 GiB, hard limit 10 GiB.
    #   "10/00000000" => caught up         "F/80000000" =>  2 GiB behind (soft<lag<hard)
    #   "F/E0000000"  => 512 MiB behind    "D/00000000" => 12 GiB behind (>hard)
    let(:standby) {
      described_class.create(
        timeline:, resource:, vm_id: create_hosted_vm(project, private_subnet, "standby").id,
        is_representative: false, synchronization_status: "ready", timeline_access: "fetch", version: "16",
      ).tap { |s| Strand.create_with_id(s, prog: "Postgres::PostgresServerNexus", label: "wait") }
    }

    replica_lag_query = "SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn(), EXTRACT(EPOCH FROM (NOW() - pg_last_xact_replay_timestamp()))::int"

    def set_primary_lsn(lsn)
      POSTGRES_MONITOR_DB[:postgres_lsn_monitor].insert(postgres_server_id: postgres_server.id, last_known_lsn: lsn)
    end

    it "does nothing for a primary" do
      expect(postgres_server).not_to receive(:_run_query)
      postgres_server.observe_replica_lag(session)
    end

    it "does nothing for a read replica whose parent is gone" do
      resource.update(parent_id: PostgresResource.generate_ubid.to_uuid)
      expect(standby).not_to receive(:_run_query)
      standby.observe_replica_lag(session)
    end

    it "does nothing while the replica is still catching up with its backup" do
      existing_page = Prog::PageNexus.assemble("#{standby.ubid} replica lag high", ["PGReplicaLagHigh", standby.id], standby.ubid, resource_id: standby.id, severity: "warning", extra_data: {byte_lag: 0, time_lag: 0, read_replica: false}).subject
      standby.strand.update(label: "wait_catch_up")
      session[:replica_lag_breach_count] = 4
      expect(standby).not_to receive(:_run_query)
      standby.observe_replica_lag(session)
      expect(existing_page.reload.semaphores.map(&:name)).to include("resolve")
      expect(session[:replica_lag_breach_count]).to eq(0)
    end

    it "resolves an existing page after the replica is promoted to primary" do
      existing_page = Prog::PageNexus.assemble("#{standby.ubid} replica lag high", ["PGReplicaLagHigh", standby.id], standby.ubid, resource_id: standby.id, severity: "warning", extra_data: {byte_lag: 0, time_lag: 0, read_replica: false}).subject
      standby.update(timeline_access: "push")
      session[:replica_lag_breach_count] = 7
      expect(standby).not_to receive(:_run_query)
      standby.observe_replica_lag(session)
      expect(existing_page.reload.semaphores.map(&:name)).to include("resolve")
      expect(session[:replica_lag_breach_count]).to eq(0)
    end

    it "resolves an existing page once the server leaves recovery, even while the row still says fetch" do
      set_primary_lsn("10/00000000")
      existing_page = Prog::PageNexus.assemble("#{standby.ubid} replica lag high", ["PGReplicaLagHigh", standby.id], standby.ubid, resource_id: standby.id, severity: "warning", extra_data: {byte_lag: 0, time_lag: 0, read_replica: false}).subject
      session[:replica_lag_breach_count] = 4
      session[:replica_lag_previous_replay_lsn] = "C/00000000"
      # 12 GiB behind, which would page, but the frozen replay lsn means nothing
      # on a server that has been promoted.
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("f,D/00000000,5")
      standby.observe_replica_lag(session)
      expect(existing_page.reload.semaphores.map(&:name)).to include("resolve")
      expect(session[:replica_lag_breach_count]).to eq(0)
      expect(session).not_to have_key(:replica_lag_previous_replay_lsn)
    end

    it "does nothing when the primary has no recorded lsn yet" do
      postgres_server
      expect(standby).not_to receive(:_run_query)
      standby.observe_replica_lag(session)
    end

    it "does nothing when the replica replay lsn is empty" do
      set_primary_lsn("10/00000000")
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("t,,100")
      standby.observe_replica_lag(session)
      expect(Page.from_tag_parts("PGReplicaLagHigh", standby.id)).to be_nil
    end

    it "treats a caught-up replica as zero lag even when the replay timestamp is old" do
      set_primary_lsn("10/00000000")
      # Replay caught up to the primary, but replay_age is huge (idle primary).
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("t,10/00000000,100000")
      session[:replica_lag_breach_count] = 4
      standby.observe_replica_lag(session)
      expect(Page.from_tag_parts("PGReplicaLagHigh", standby.id)).to be_nil
      expect(session[:replica_lag_breach_count]).to eq(0)
    end

    [96, 8192].each do |byte_lag|
      it "ignores an old replay timestamp with a stable #{byte_lag}-byte WAL gap" do
        set_primary_lsn("10/#{byte_lag.to_s(16)}")
        expect(standby.vm.sshable).to receive(:_cmd).with(
          "PGOPTIONS=-c\\ statement_timeout\\=5s psql -U ubi_monitoring -d ubi_admin -t --csv -v 'ON_ERROR_STOP=1'", stdin: replica_lag_query,
        ).exactly(5).times.and_return("t,10/00000000,100000")

        5.times { standby.observe_replica_lag(session) }

        expect(Page.from_tag_parts("PGReplicaLagHigh", standby.id)).to be_nil
        expect(session[:replica_lag_breach_count]).to eq(0)
      end
    end

    it "resolves an existing page when only a small WAL tail remains" do
      set_primary_lsn("10/00000060")
      existing_page = Prog::PageNexus.assemble("#{standby.ubid} replica lag high", ["PGReplicaLagHigh", standby.id], standby.ubid, resource_id: standby.id, severity: "warning", extra_data: {byte_lag: 96, time_lag: 100000, read_replica: false}).subject
      session[:replica_lag_breach_count] = 5
      expect(standby.vm.sshable).to receive(:_cmd).with(
        "PGOPTIONS=-c\\ statement_timeout\\=5s psql -U ubi_monitoring -d ubi_admin -t --csv -v 'ON_ERROR_STOP=1'", stdin: replica_lag_query,
      ).and_return("t,10/00000000,100000")

      standby.observe_replica_lag(session)

      expect(existing_page.reload.semaphores.map(&:name)).to include("resolve")
      expect(session[:replica_lag_breach_count]).to eq(0)
    end

    it "pages after five time breaches when the WAL gap exceeds one page" do
      set_primary_lsn("10/00002001")
      expect(standby.vm.sshable).to receive(:_cmd).with(
        "PGOPTIONS=-c\\ statement_timeout\\=5s psql -U ubi_monitoring -d ubi_admin -t --csv -v 'ON_ERROR_STOP=1'", stdin: replica_lag_query,
      ).exactly(5).times.and_return("t,10/00000000,1000")

      4.times { standby.observe_replica_lag(session) }
      expect(Page.from_tag_parts("PGReplicaLagHigh", standby.id)).to be_nil

      standby.observe_replica_lag(session)

      page = Page.from_tag_parts("PGReplicaLagHigh", standby.id)
      expect(page.details["byte_lag"]).to eq(8193)
      expect(page.details["time_lag"]).to eq(1000)
      expect(page.severity).to eq("warning")
    end

    it "does not page while the replica is past the soft limit but still making progress" do
      set_primary_lsn("10/00000000")
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return(
        "t,F/80000000,5", "t,F/88000000,5", "t,F/90000000,5", "t,F/98000000,5", "t,F/A0000000,5",
      )
      5.times { standby.observe_replica_lag(session) }
      expect(Page.from_tag_parts("PGReplicaLagHigh", standby.id)).to be_nil
      expect(session[:replica_lag_breach_count]).to be_nil
    end

    it "pages when the replica is past the soft limit and stalled for the 5th consecutive check" do
      set_primary_lsn("10/00000000")
      session[:replica_lag_breach_count] = 3
      session[:replica_lag_previous_replay_lsn] = "F/80000000"
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("t,F/80000000,5", "t,F/80000000,5") # same lsn as previous => no progress
      2.times { standby.observe_replica_lag(session) }
      expect(Page.from_tag_parts("PGReplicaLagHigh", standby.id).resource_id).to eq(standby.id)
    end

    it "pages past the hard limit even while the replica is making progress" do
      set_primary_lsn("10/00000000")
      session[:replica_lag_breach_count] = 4
      session[:replica_lag_previous_replay_lsn] = "C/00000000"
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("t,D/00000000,5") # 12 GiB behind, but progressed from C/0
      standby.observe_replica_lag(session)
      expect(Page.from_tag_parts("PGReplicaLagHigh", standby.id)).not_to be_nil
    end

    it "pages on time lag even when byte lag is below the soft limit" do
      set_primary_lsn("10/00000000")
      session[:replica_lag_breach_count] = 4
      session[:replica_lag_previous_replay_lsn] = "F/E0000000"
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("t,F/E0000000,1000") # 512 MiB behind, replay 1000s old
      standby.observe_replica_lag(session)
      expect(Page.from_tag_parts("PGReplicaLagHigh", standby.id)).not_to be_nil
    end

    it "resolves an existing page once lag recovers" do
      set_primary_lsn("10/00000000")
      existing_page = Prog::PageNexus.assemble("#{standby.ubid} replica lag high", ["PGReplicaLagHigh", standby.id], standby.ubid, resource_id: standby.id, severity: "warning", extra_data: {byte_lag: 0, time_lag: 0, read_replica: false}).subject
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("t,10/00000000,5") # caught up
      standby.observe_replica_lag(session)
      expect(existing_page.reload.semaphores.map(&:name)).to include("resolve")
    end

    it "logs and does not raise when the replica query fails" do
      set_primary_lsn("10/00000000")
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_raise("boom")
      expect(Clog).to receive(:emit).with("Failed to observe replica lag", instance_of(Hash)).and_call_original
      standby.observe_replica_lag(session)
    end

    it "for read replicas it uses the parent's primary lsn" do
      parent_resource = create_postgres_resource(project:, location_id: location.id)
      parent_primary = described_class.create(
        timeline:, resource: parent_resource, vm_id: create_hosted_vm(project, private_subnet, "parent-vm").id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "16",
      )
      resource.update(parent: parent_resource)
      postgres_server.update(timeline_access: "fetch")
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
      POSTGRES_MONITOR_DB[:postgres_lsn_monitor].insert(postgres_server_id: parent_primary.id, last_known_lsn: "10/00000000")

      expect(postgres_server.read_replica?).to be(true)
      session[:replica_lag_breach_count] = 4
      session[:replica_lag_previous_replay_lsn] = "C/00000000"
      expect(postgres_server).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("t,D/00000000,5") # 12 GiB behind > hard
      postgres_server.observe_replica_lag(session)
      page = Page.from_tag_parts("PGReplicaLagHigh", postgres_server.id)
      expect(page).not_to be_nil
      expect(page.details["read_replica"]).to be(true)
    end

    it "looks for a page only once per session while the server is not a lag subject" do
      postgres_server.observe_replica_lag(session)
      page = Prog::PageNexus.assemble("#{postgres_server.ubid} replica lag high", ["PGReplicaLagHigh", postgres_server.id], postgres_server.ubid, resource_id: postgres_server.id, severity: "warning", extra_data: {byte_lag: 0, time_lag: 0, read_replica: false}).subject
      postgres_server.observe_replica_lag(session)
      expect(page.reload.semaphores.map(&:name)).not_to include("resolve")
    end

    it "looks for a page again after it has paged in the same session" do
      set_primary_lsn("10/00000000")
      standby.update(timeline_access: "push")
      standby.observe_replica_lag(session)

      standby.update(timeline_access: "fetch")
      session[:replica_lag_breach_count] = 4
      session[:replica_lag_previous_replay_lsn] = "C/00000000"
      expect(standby).to receive(:_run_query).with(replica_lag_query, user: "ubi_monitoring", dbname: "ubi_admin", statement_timeout: 5).and_return("t,D/00000000,5")
      standby.observe_replica_lag(session)
      page = Page.from_tag_parts("PGReplicaLagHigh", standby.id)
      expect(page).not_to be_nil

      standby.update(timeline_access: "push")
      standby.observe_replica_lag(session)
      expect(page.reload.semaphores.map(&:name)).to include("resolve")
    end
  end

  describe "#observe_data_disk_usage" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    it "increments check_disk_usage on the resource when primary and usage >= 77%" do
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  80%\n")
      postgres_server.observe_data_disk_usage(session)
      expect(Semaphore.where(strand_id: resource.strand.id, name: "check_disk_usage").count).to eq(1)
    end

    it "does nothing when primary and usage < 77% and no prior auto-scale action" do
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  50%\n")
      expect(resource).not_to receive(:incr_check_disk_usage)
      postgres_server.observe_data_disk_usage(session)
    end

    it "increments check_disk_usage when primary and usage < 77% but storage_auto_scale_action_performed_80 is set" do
      resource.incr_storage_auto_scale_action_performed_80
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  50%\n")
      postgres_server.observe_data_disk_usage(session)
      expect(Semaphore.where(strand_id: resource.strand.id, name: "check_disk_usage").count).to eq(1)
    end

    it "does not duplicate check_disk_usage semaphore when already set on primary" do
      resource.incr_check_disk_usage
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  80%\n")
      postgres_server.observe_data_disk_usage(session)
      expect(Semaphore.where(strand_id: resource.strand.id, name: "check_disk_usage").count).to eq(1)
    end

    it "creates a page for non-primary server with usage >= 95%" do
      postgres_server.update(is_representative: false, timeline_access: "fetch")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  96%\n")
      postgres_server.observe_data_disk_usage(session)

      page = Page.from_tag_parts("PGDiskUsageHigh", postgres_server.id)
      expect(page.summary).to eq("High disk usage on non-primary PG server (96%)")
      expect(page.severity).to eq("warning")
      expect(page.details["disk_usage_percent"]).to eq(96)
      expect(page.details["related_resources"]).to eq([postgres_server.ubid])
      expect(page.resource_id).to eq(postgres_server.id)
    end

    it "resolves PGDiskUsageHigh page for non-primary server with usage < 95%" do
      postgres_server.update(is_representative: false, timeline_access: "fetch")
      page = Prog::PageNexus.assemble("High disk usage on non-primary PG server", ["PGDiskUsageHigh", postgres_server.id], postgres_server.ubid, resource_id: postgres_server.id, severity: "warning")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")
      postgres_server.observe_data_disk_usage(session)
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
    end

    it "does nothing for non-primary server with usage < 95% and no existing page" do
      postgres_server.update(is_representative: false, timeline_access: "fetch")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")
      expect(Prog::PageNexus).not_to receive(:assemble)
      expect(resource).not_to receive(:incr_check_disk_usage)
      postgres_server.observe_data_disk_usage(session)
    end

    it "logs errors when checking data disk usage fails" do
      expect(session[:ssh_session]).to receive(:_exec!).and_raise(Net::SSH::Exception.new("SSH error"))
      expect(Clog).to receive(:emit).with("Failed to observe data disk usage", instance_of(Hash)).and_call_original
      postgres_server.observe_data_disk_usage(session)
    end
  end

  describe "disk usage monitor persistence" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    after do
      POSTGRES_MONITOR_DB[:postgres_disk_usage_monitor].where(postgres_server_id: postgres_server.id).delete
    end

    it "observe_data_disk_usage upserts the observed percent with a timestamp" do
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  42%\n")
      postgres_server.observe_data_disk_usage(session)
      row = postgres_server.disk_usage_monitor_ds.first
      expect(row[:data_disk_usage_percent]).to eq(42)
      expect(row[:observed_at]).not_to be_nil

      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent /dat | tail -n 1").and_return("  43%\n")
      postgres_server.observe_data_disk_usage(session)
      expect(postgres_server.disk_usage_monitor_ds.count).to eq(1)
      expect(postgres_server.disk_usage_monitor_ds.get(:data_disk_usage_percent)).to eq(43)
    end

    it "observed_disk_usage_percent returns fresh observations and nil for stale or missing ones" do
      expect(postgres_server.observed_disk_usage_percent).to be_nil

      POSTGRES_MONITOR_DB[:postgres_disk_usage_monitor].insert(postgres_server_id: postgres_server.id, data_disk_usage_percent: 42, observed_at: Time.now - PostgresServer::DISK_USAGE_MAX_AGE_SECONDS - 60)
      expect(postgres_server.observed_disk_usage_percent).to be_nil

      postgres_server.disk_usage_monitor_ds.update(observed_at: Time.now)
      expect(postgres_server.observed_disk_usage_percent).to eq(42)
    end

    it "deletes the monitor row on destroy" do
      POSTGRES_MONITOR_DB[:postgres_disk_usage_monitor].insert(postgres_server_id: postgres_server.id, data_disk_usage_percent: 42, observed_at: Time.now)
      postgres_server.destroy
      expect(POSTGRES_MONITOR_DB[:postgres_disk_usage_monitor].where(postgres_server_id: postgres_server.id).count).to eq(0)
    end
  end

  describe "#observe_root_disk_usage" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }

    it "creates an error page for primary server with usage >= 95%" do
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent / | tail -n 1").and_return("  96%\n")
      postgres_server.observe_root_disk_usage(session)

      page = Page.from_tag_parts("PGRootDiskUsageHigh", postgres_server.id)
      expect(page.summary).to eq("High root disk usage on PG server (96%)")
      expect(page.severity).to eq("error")
      expect(page.details["root_disk_usage_percent"]).to eq(96)
      expect(page.details["related_resources"]).to eq([postgres_server.ubid])
      expect(page.resource_id).to eq(postgres_server.id)
    end

    it "creates a warning page for non-primary server with usage >= 95%" do
      postgres_server.update(is_representative: false, timeline_access: "fetch")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent / | tail -n 1").and_return("  96%\n")
      postgres_server.observe_root_disk_usage(session)

      page = Page.from_tag_parts("PGRootDiskUsageHigh", postgres_server.id)
      expect(page.summary).to eq("High root disk usage on PG server (96%)")
      expect(page.severity).to eq("warning")
      expect(page.details["root_disk_usage_percent"]).to eq(96)
      expect(page.details["related_resources"]).to eq([postgres_server.ubid])
      expect(page.resource_id).to eq(postgres_server.id)
    end

    it "resolves PGRootDiskUsageHigh page when usage < 95%" do
      page = Prog::PageNexus.assemble("High root disk usage on PG server", ["PGRootDiskUsageHigh", postgres_server.id], postgres_server.ubid, resource_id: postgres_server.id, severity: "error")
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent / | tail -n 1").and_return("  85%\n")
      postgres_server.observe_root_disk_usage(session)
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
    end

    it "does nothing when usage < 95% and no existing page" do
      expect(session[:ssh_session]).to receive(:_exec!).with("df --output=pcent / | tail -n 1").and_return("  85%\n")
      expect(Prog::PageNexus).not_to receive(:assemble)
      postgres_server.observe_root_disk_usage(session)
    end

    it "logs errors when checking root disk usage fails" do
      expect(session[:ssh_session]).to receive(:_exec!).and_raise(Net::SSH::Exception.new("SSH error"))
      expect(Clog).to receive(:emit).with("Failed to observe root disk usage", instance_of(Hash)).and_call_original
      postgres_server.observe_root_disk_usage(session)
    end
  end

  describe "#observe_io_throttle" do
    let(:session) {
      {ssh_session: Net::SSH::Connection::Session.allocate}
    }
    let(:io_throttle_cmd) { "stat -c '%Y' /sys/fs/cgroup/system.slice/system-postgresql.slice/postgresql@16-main.service/throttled/io.max 2>/dev/null || echo missing; date +%s" }
    let(:vm_now) { Time.now.to_i }

    it "does nothing when io.max file is missing" do
      expect(session[:ssh_session]).to receive(:_exec!).with(io_throttle_cmd).and_return("missing\n#{vm_now}\n")
      expect(Prog::PageNexus).not_to receive(:assemble)
      postgres_server.observe_io_throttle(session)
    end

    it "creates a stale page when io.max mtime is older than 120 seconds" do
      old_mtime = vm_now - 121
      expect(session[:ssh_session]).to receive(:_exec!).with(io_throttle_cmd).and_return("#{old_mtime}\n#{vm_now}\n")
      postgres_server.observe_io_throttle(session)

      page = Page.from_tag_parts("PGIOThrottleStale", postgres_server.id)
      expect(page.summary).to eq("#{postgres_server.ubid} I/O throttle stale")
      expect(page.severity).to eq("warning")
      expect(page.details["io_max_mtime"]).to eq(Time.at(old_mtime).to_s)
      expect(page.details["related_resources"]).to eq([postgres_server.ubid])
      expect(page.resource_id).to eq(postgres_server.id)
    end

    it "resolves stale page and logs when io.max mtime is recent" do
      recent_mtime = vm_now - 10
      expect(session[:ssh_session]).to receive(:_exec!).with(io_throttle_cmd).and_return("#{recent_mtime}\n#{vm_now}\n")
      page = Prog::PageNexus.assemble("#{postgres_server.ubid} I/O throttle stale",
        ["PGIOThrottleStale", postgres_server.id], postgres_server.ubid, resource_id: postgres_server.id, severity: "warning")
      postgres_server.observe_io_throttle(session)
      expect(Semaphore.where(strand_id: page.id, name: "resolve").count).to eq(1)
    end

    it "does not fail resolving stale page when no existing page" do
      recent_mtime = vm_now - 10
      expect(session[:ssh_session]).to receive(:_exec!).with(io_throttle_cmd).and_return("#{recent_mtime}\n#{vm_now}\n")
      expect(Prog::PageNexus).not_to receive(:assemble)
      postgres_server.observe_io_throttle(session)
    end
  end

  if Config.unfrozen_test?
    describe "#attach_s3_policy_if_needed" do
      it "calls attach_role_policy when needs s3 policy attachment" do
        location.update(provider: "aws")
        expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
        AwsInstance.create_with_id(vm, iam_role: "role")
        iam_client = Aws::IAM::Client.new(stub_responses: true)
        LocationCredentialAws.create(location:, assume_role: "role")

        expect(postgres_server.timeline.location.location_credential_aws).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
        expect(postgres_server.timeline.location.location_credential_aws).to receive(:iam_client).and_return(iam_client)
        expect(iam_client).to receive(:attach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.aws_s3_policy_arn)
        postgres_server.attach_s3_policy_if_needed
      end

      it "detaches parent timeline when Config.aws_postgres_iam_access set" do
        location.update(provider: "aws")
        expect(Config).to receive(:aws_postgres_iam_access).and_return(true)
        AwsInstance.create_with_id(vm, iam_role: "role")
        iam_client = Aws::IAM::Client.new(stub_responses: true)
        LocationCredentialAws.create(location:, assume_role: "role")

        parent = create_postgres_timeline(location_id: location.id)
        timeline.update(parent:)
        expect(postgres_server.timeline.location.location_credential_aws).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
        expect(postgres_server.timeline.location.location_credential_aws).to receive(:iam_client).and_return(iam_client)
        expect(postgres_server.timeline.parent.location.location_credential_aws).to receive(:aws_iam_account_id).and_return("aws-account-id").at_least(:once)
        expect(iam_client).to receive(:attach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.aws_s3_policy_arn)
        expect(iam_client).to receive(:detach_role_policy).with(role_name: "role", policy_arn: postgres_server.timeline.parent.aws_s3_policy_arn)
        postgres_server.attach_s3_policy_if_needed
      end

      it "does not detach parent timeline when Config.aws_postgres_iam_access not set" do
        location.update(provider: "aws")
        AwsInstance.create_with_id(vm, iam_role: "role")
        LocationCredentialAws.create(location:, assume_role: "role")

        expect(postgres_server.vm.aws_instance).not_to receive(:iam_role)
        postgres_server.attach_s3_policy_if_needed
      end

      it "does not call attach_role_policy when needs s3 policy attachment" do
        LocationCredentialAws.create(location:, assume_role: "role")
        expect(postgres_server.timeline.location.location_credential_aws).not_to receive(:aws_iam_account_id)
        postgres_server.attach_s3_policy_if_needed
      end
    end
  end

  describe "#run_query" do
    it "raises if given interpolated string" do
      string = "string"
      expect { postgres_server.run_query("interpolated #{string}") }.to raise_error(NetSsh::PotentialInsecurity)
    end
  end

  describe "#display_state" do
    before do
      Strand.create_with_id(postgres_server, prog: "Postgres::PostgresServerNexus", label: "wait")
    end

    it "maps the strand label to a display state" do
      states = %w[wait unavailable taking_over wait_catch_up wait_synchronization destroy configure refresh_certificates].to_h do |label|
        postgres_server.strand.update(label:)
        [label, postgres_server.display_state]
      end
      expect(states).to eq(
        "wait" => "running",
        "unavailable" => "unavailable",
        "taking_over" => "failing_over",
        "wait_catch_up" => "synchronizing",
        "wait_synchronization" => "synchronizing",
        "destroy" => "deleting",
        "configure" => "updating",
        "refresh_certificates" => "updating",
      )
    end

    it "returns restarting while a restart is pending" do
      postgres_server.incr_restart
      expect(postgres_server.display_state).to eq("restarting")
    end

    it "returns creating when initial_provisioning semaphore is set" do
      postgres_server.strand.update(label: "mount_data_disk")
      postgres_server.incr_initial_provisioning
      expect(postgres_server.display_state).to eq("creating")
    end
  end

  describe "#metrics_config" do
    it "labels the exported metrics with the location and tags" do
      resource.update(tags: [{"key" => "env", "value" => "prod"}])

      expect(postgres_server.metrics_config[:additional_labels]).to eq({"pg_tags_label_env" => "prod"}.merge(
        location_id: location.ubid,
        location_name: "us-west-2",
        location_provider: "ubicloud",
        location_display_name: "us-west-2",
      ))
    end
  end

  describe "#logs_config" do
    it "returns the server identity and role, with no destinations and no AWS-only agents outside AWS" do
      config = postgres_server.logs_config
      expect(config.values_at(:instance, :resource_name, :resource_id, :server_role, :version, :log_destinations, :cloudwatch_auth_region, :guardduty_region)).to eq [
        postgres_server.ubid, resource.name, resource.ubid, "primary", "16", [], nil, nil,
      ]

      postgres_server.update(timeline_access: "fetch")
      expect(postgres_server.logs_config[:server_role]).to eq("standby")
    end

    context "with an AWS location" do
      let(:location) {
        Location.create(
          name: "us-west-2",
          project:,
          display_name: "aws-us-west-2",
          ui_name: "aws-us-west-2",
          provider: "aws",
          visible: true,
        )
      }

      it "ships auth logs to CloudWatch and installs the GuardDuty agent from the server's region only for a project with the feature flag" do
        expect(postgres_server.logs_config.values_at(:cloudwatch_auth_region, :guardduty_region)).to eq [nil, nil]
        project.set_ff_aws_cloudwatch_logs(true)
        expect(postgres_server.logs_config.values_at(:cloudwatch_auth_region, :guardduty_region)).to eq ["us-west-2", "us-west-2"]
      end
    end

    it "includes log destinations" do
      PostgresLogDestination.create(
        postgres_resource_id: resource.id,
        name: "graylog",
        type: "syslog",
        url: "tcp://logs.example.com:6514",
      )
      destinations = postgres_server.logs_config[:log_destinations]
      expect(destinations.length).to eq(1)
      expect(destinations.first).to eq({type: "syslog", url: "tcp://logs.example.com:6514", options: nil})
    end

    context "with a managed Parseable service" do
      let(:parseable_project) { Project.create(name: "parseable-svc") }
      let(:parseable_resource) {
        ParseableResource.create(
          location_id: location.id,
          name: "test-parseable",
          admin_user: "admin",
          admin_password: "dummy-password",
          root_cert_1: "root_cert_1",
          root_cert_key_1: "root_cert_key_1",
          root_cert_2: "root_cert_2",
          root_cert_key_2: "root_cert_key_2",
          blob_storage_access_key: "access-key",
          blob_storage_secret_key: "secret-key",
          target_vm_size: "standard-2",
          target_storage_size_gib: 100,
          project_id: parseable_project.id,
        )
      }

      before do
        allow(Config).to receive_messages(
          postgres_service_project_id: parseable_project.id,
          parseable_host_name: "parseable.example.com",
          parseable_endpoint_override: nil,
        )
        parseable_resource
      end

      it "emits no managed parseable destination when no server exists" do
        expect(postgres_server.logs_config[:log_destinations]).to eq([])
      end

      it "emits no managed parseable destination when log aggregation setup hasn't completed yet" do
        ParseableServer.create(parseable_resource_id: parseable_resource.id, vm_id: vm.id)
        expect(resource.parseable_password).to be_nil

        expect(postgres_server.logs_config[:log_destinations]).to eq([])
      end

      it "emits a managed parseable destination with auth, CA bundle, and JSON encoding when credentials are set" do
        ps = ParseableServer.create(parseable_resource_id: parseable_resource.id, vm_id: vm.id)
        resource.update(parseable_password: "scoped-pw")

        destinations = postgres_server.logs_config[:log_destinations]
        expect(destinations.length).to eq(1)
        managed = destinations.first
        expect(managed[:type]).to eq("otlp")
        expect(managed[:url]).to eq(ps.endpoint)
        expect(managed[:options]["encoding"]).to eq("json")
        expect(managed[:options]["ca_bundle"]).to eq(parseable_resource.root_certs)
        expected_auth = "Basic " + Base64.strict_encode64("#{resource.ubid}:scoped-pw")
        expect(managed[:options]["headers"]).to include(
          "X-P-Stream" => resource.ubid,
          "X-P-Log-Source" => "otel-logs",
          "Authorization" => expected_auth,
        )
      end

      it "places the managed parseable destination before user-configured destinations" do
        ParseableServer.create(parseable_resource_id: parseable_resource.id, vm_id: vm.id)
        resource.update(parseable_password: "scoped-pw")
        PostgresLogDestination.create(
          postgres_resource_id: resource.id,
          name: "graylog",
          type: "syslog",
          url: "tcp://logs.example.com:6514",
        )

        destinations = postgres_server.logs_config[:log_destinations]
        expect(destinations.map { |d| d[:type] }).to eq(["otlp", "syslog"])
      end

      it "uses endpoint override without auth or CA bundle when parseable_endpoint_override is set" do
        expect(Config).to receive_messages(
          parseable_endpoint_override: "https://parseable-dev.example.com:8000",
        )
        destinations = postgres_server.logs_config[:log_destinations]
        expect(destinations.length).to eq(1)
        managed = destinations.first
        expect(managed[:url]).to eq("https://parseable-dev.example.com:8000")
        expect(managed[:options]["headers"]).not_to have_key("Authorization")
        expect(managed[:options]).not_to have_key("ca_bundle")
      end
    end
  end
end
