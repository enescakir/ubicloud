# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresResource do
  subject(:postgres_resource) {
    pr = described_class.create(
      name: "pg-name",
      superuser_password: "dummy-password",
      ha_type: "none",
      target_version: "17",
      location_id:,
      project_id: project.id,
      user_config: {},
      pgbouncer_user_config: {},
      target_vm_size: "standard-2",
      target_storage_size_gib: 64,
    )
    fw = Firewall.create(name: pr.ubid + "-internal-firewall", project_id: project.id, location_id:)
    fw.associate_with_private_subnet(private_subnet)

    Strand.create_with_id(pr, prog: "Postgres::PostgresResourceNexus", label: "wait")
    pr
  }

  let(:project) { Project.create(name: "pg-test-project") }
  let(:location_id) { Location::HETZNER_FSN1_ID }
  let(:location) { Location[location_id] }
  let(:timeline) { create_postgres_timeline(location_id:) }
  let(:private_subnet) {
    PrivateSubnet.create(
      name: "pg-subnet", project_id: project.id, location_id:,
      net4: "172.0.0.0/26", net6: "fdfa:b5aa:14a3:4a3d::/64",
    )
  }

  it "#uses_publicly_signed_certificates? is only true if all conditions are met" do
    expect(postgres_resource.uses_publicly_signed_certificates?).to be false

    postgres_project = Project.create(name: "pg-service-project")
    expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)
    expect(Config).to receive(:acme_email).and_return("acme@example.com").exactly(5)
    postgres_resource.hostname_version = "v3"
    dns_zone = DnsZone.create(project_id: postgres_project.id, name: "pg.ubicloud.app")
    expect(postgres_resource.uses_publicly_signed_certificates?).to be true

    postgres_resource.location.dns_suffix = ".eu"
    expect(postgres_resource.uses_publicly_signed_certificates?).to be false
    postgres_resource.location.dns_suffix = nil

    postgres_resource.project.set_ff_postgres_hostname_override(true)
    expect(postgres_resource.uses_publicly_signed_certificates?).to be false
    postgres_resource.project.set_ff_postgres_hostname_override(false)

    postgres_resource.hostname_version = "v2"
    expect(postgres_resource.uses_publicly_signed_certificates?).to be false
    postgres_resource.hostname_version = "v3"

    dns_zone.destroy
    postgres_resource.instance_variable_set(:@dns_zone, nil)
    expect(postgres_resource.uses_publicly_signed_certificates?).to be false
    DnsZone.create(project_id: postgres_project.id, name: "pg.ubicloud.app")

    expect(postgres_resource.uses_publicly_signed_certificates?).to be true
    expect(Config).to receive(:acme_email).and_return(nil)
    expect(postgres_resource.uses_publicly_signed_certificates?).to be false
  end

  describe "with the postgres service DNS zones" do
    let(:service_project) { Project.create(name: "pg-service-project") }

    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(service_project.id)
      DnsZone.create(project_id: service_project.id, name: "postgres.ubicloud.com")
      DnsZone.create(project_id: service_project.id, name: "pg.ubicloud.app")
    end

    it "returns connection strings qualified by ubid from hostname version v2" do
      postgres_resource.update(hostname_version: "v1")
      expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.postgres.ubicloud.com:5432/postgres?sslmode=require&channel_binding=require")
      postgres_resource.update(hostname_version: "v2")
      expect([postgres_resource.connection_string, postgres_resource.private_connection_string]).to eq [
        "postgres://postgres:dummy-password@pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com:5432/postgres?sslmode=require&channel_binding=require",
        "postgres://postgres:dummy-password@private.pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com:5432/postgres?sslmode=require&channel_binding=require",
      ]
    end

    it "returns connection strings for publicly signed certificates with hostname version v3" do
      expect(Config).to receive(:acme_email).and_return("acme@example.com").at_least(:once)
      postgres_resource.update(hostname_version: "v3")
      expect([postgres_resource.connection_string, postgres_resource.private_connection_string]).to eq [
        "postgres://postgres:dummy-password@pg-name.#{postgres_resource.ubid}.pg.ubicloud.app:5432/postgres?sslmode=verify-full&channel_binding=require&sslrootcert=system",
        "postgres://postgres:dummy-password@pg-name.#{postgres_resource.ubid}.private.pg.ubicloud.app:5432/postgres?sslmode=verify-full&channel_binding=require&sslrootcert=system",
      ]
    end

    it "returns replication_connection_string with the private hostname, using the server CA only when root certs are set" do
      params = "sslcert=/etc/ssl/certs/client.crt&sslkey=/etc/ssl/certs/client.key&sslmode=verify-full&dbname=postgres&application_name=pgubidstandby&tcp_user_timeout=30000"
      strings = [["v1", nil], ["v2", "rc"], ["v3", nil]].map do |hostname_version, root_cert|
        postgres_resource.update(hostname_version:, root_cert_1: root_cert, root_cert_2: root_cert)
        described_class[postgres_resource.id].replication_connection_string(application_name: "pgubidstandby")
      end
      expect(strings).to eq [
        "postgres://ubi_replication@private.pg-name.postgres.ubicloud.com?sslrootcert=system&#{params}",
        "postgres://ubi_replication@private.pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com?sslrootcert=/etc/ssl/certs/server-ca.crt&#{params}",
        "postgres://ubi_replication@pg-name.#{postgres_resource.ubid}.private.pg.ubicloud.app?sslrootcert=system&#{params}",
      ]
    end
  end

  describe "without a postgres service DNS zone" do
    before do
      vm = create_hosted_vm(project, private_subnet, "pg-vm")
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id, is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "1.2.3.4/32")
      vm.nics.first.update(private_ipv4: "172.0.0.9/32")
    end

    it "returns connection strings with the ip addresses of the representative server" do
      expect(postgres_resource.dns_zone).to be_nil
      expect(postgres_resource.connection_string).to eq("postgres://postgres:dummy-password@1.2.3.4:5432/postgres?sslmode=require&channel_binding=require")
      expect(postgres_resource.replication_connection_string(application_name: "pgubidstandby")).to eq("postgres://ubi_replication@172.0.0.9?sslrootcert=system&sslcert=/etc/ssl/certs/client.crt&sslkey=/etc/ssl/certs/client.key&sslmode=require&dbname=postgres&application_name=pgubidstandby&tcp_user_timeout=30000")
    end
  end

  it "returns internal_firewall_rules with SSH from control plane, subnet ports 5432/6432, and configured external CIDRs" do
    expect(Config).to receive_messages(control_plane_outbound_cidrs: ["1.2.3.4/32"], postgres_internal_firewall_cidrs: ["5.6.7.8/32"])

    postgres_resource.update(private_subnet_id: private_subnet.id)
    rendered = postgres_resource.internal_firewall_rules.map { "#{it[:cidr]}:#{it[:port_range].to_range}" }
    expect(rendered).to contain_exactly(
      "1.2.3.4/32:22..22",
      "#{private_subnet.net4}:5432..5432",
      "#{private_subnet.net4}:6432..6432",
      "#{private_subnet.net6}:5432..5432",
      "#{private_subnet.net6}:6432..6432",
      "5.6.7.8/32:5432..5432",
      "5.6.7.8/32:6432..6432",
    )
  end

  describe "#mgmt_ssh_via_user_security_group?" do
    it "is true off AWS, keeping port 22 in the internal firewall" do
      postgres_resource.update(private_subnet_id: private_subnet.id)
      expect(postgres_resource.mgmt_ssh_via_user_security_group?).to be true
    end

    context "when on AWS" do
      let(:aws_location) {
        Location.create(name: "us-west-2", provider: "aws", display_name: "aws-us-west-2sg",
          ui_name: "AWS US West 2 SG", visible: true)
      }
      let(:aws_subnet) {
        PrivateSubnet.create(name: "aws-sg-subnet", project_id: project.id, location_id: aws_location.id,
          net4: "172.0.2.0/26", net6: "fdfa:b5aa:14a3:4a3f::/64")
      }
      let(:aws_timeline) { create_postgres_timeline(location_id: aws_location.id) }
      let(:aws_resource) {
        described_class.create(
          name: "pg-aws-sg", superuser_password: "dummy-password", ha_type: "none",
          target_version: "17", location_id: aws_location.id, project_id: project.id,
          user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
          target_storage_size_gib: 64, private_subnet_id: aws_subnet.id,
        )
      }

      def create_aws_server(name, with_mgmt_nic:)
        vm = Prog::Vm::Nexus.assemble_with_sshable(
          project.id, name:, private_subnet_id: aws_subnet.id,
          location_id: aws_location.id, unix_user: "ubi", boot_image: "ami-12345678",
        ).subject
        if with_mgmt_nic
          Prog::Vnet::NicNexus.assemble(aws_subnet.id, name: "#{name}-mgmt-nic", is_management: true).subject.update(vm_id: vm.id)
        end
        PostgresServer.create(timeline: aws_timeline, resource_id: aws_resource.id, vm_id: vm.id,
          synchronization_status: "ready", timeline_access: "push", version: "17")
      end

      describe "#aws_ssh_ipv6?" do
        it "is false for a non-AWS resource" do
          expect(postgres_resource.aws_ssh_ipv6?).to be false
        end

        it "is false when the feature flag is off" do
          PrivateSubnetAwsResource.create_with_id(aws_subnet.id, user_security_group_id: "sg-user", mgmt_security_group_id: "sg-mgmt")
          expect(aws_resource.aws_ssh_ipv6?).to be false
        end

        it "is false when the subnet lacks a dedicated mgmt security group" do
          project.set_ff_postgres_aws_ssh_ipv6(true)
          PrivateSubnetAwsResource.create_with_id(aws_subnet.id, user_security_group_id: "sg-shared", mgmt_security_group_id: "sg-shared")
          expect(aws_resource.aws_ssh_ipv6?).to be false
        end

        it "is true when the flag is on and a dedicated mgmt group exists" do
          project.set_ff_postgres_aws_ssh_ipv6(true)
          PrivateSubnetAwsResource.create_with_id(aws_subnet.id, user_security_group_id: "sg-user", mgmt_security_group_id: "sg-mgmt")
          expect(aws_resource.aws_ssh_ipv6?).to be true
        end
      end

      it "is false with no servers yet, so new resources omit port 22" do
        expect(aws_resource.mgmt_ssh_via_user_security_group?).to be false
        expect(aws_resource.internal_firewall_rules.select { it[:port_range].to_range.cover?(22) }).to be_empty
      end

      it "is true when the subnet has no aws resource record" do
        create_aws_server("aws-sg-vm1", with_mgmt_nic: true)
        expect(aws_resource.mgmt_ssh_via_user_security_group?).to be true
      end

      it "is true while the legacy shared group serves both roles" do
        create_aws_server("aws-sg-vm1", with_mgmt_nic: true)
        PrivateSubnetAwsResource.create_with_id(aws_subnet.id, user_security_group_id: "sg-shared", mgmt_security_group_id: "sg-shared")
        expect(aws_resource.mgmt_ssh_via_user_security_group?).to be true
      end

      it "is true while a server lacks a management NIC" do
        PrivateSubnetAwsResource.create_with_id(aws_subnet.id, user_security_group_id: "sg-user", mgmt_security_group_id: "sg-mgmt")
        create_aws_server("aws-sg-vm1", with_mgmt_nic: true)
        create_aws_server("aws-sg-vm2", with_mgmt_nic: false)
        expect(aws_resource.mgmt_ssh_via_user_security_group?).to be true
      end

      it "is false once every server has a management NIC and the mgmt group is dedicated" do
        PrivateSubnetAwsResource.create_with_id(aws_subnet.id, user_security_group_id: "sg-user", mgmt_security_group_id: "sg-mgmt")
        create_aws_server("aws-sg-vm1", with_mgmt_nic: true)
        expect(aws_resource.mgmt_ssh_via_user_security_group?).to be false
        expect(aws_resource.internal_firewall_rules.select { it[:port_range].to_range.cover?(22) }).to be_empty
      end
    end
  end

  it "client_ca_certificates is nil while either client_root_cert_1 or client_root_cert_2 also nil" do
    postgres_resource.update(client_root_cert_1: "1", client_root_cert_2: "2")
    expect(postgres_resource.client_ca_certificates).not_to be_nil
    postgres_resource.update(client_root_cert_1: nil, client_root_cert_2: "2")
    expect(postgres_resource.client_ca_certificates).to be_nil
    postgres_resource.update(client_root_cert_1: "1", client_root_cert_2: nil)
    expect(postgres_resource.client_ca_certificates).to be_nil
  end

  describe "#update_target_sizes_with_replicas" do
    let(:replica) {
      described_class.create(
        name: "pg-replica", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id:, project_id: project.id, user_config: {},
        pgbouncer_user_config: {}, target_vm_size: "standard-2", target_storage_size_gib: 64,
        parent_id: postgres_resource.id,
      )
    }

    it "updates self and each read replica, leaving a ubicloud.shared_memory_percent the new size allows" do
      postgres_resource.update(user_config: {"ubicloud.shared_memory_percent" => "50"})
      replica.update(user_config: {"work_mem" => "32MB"})

      postgres_resource.update_target_sizes_with_replicas(target_vm_size: "standard-8", target_storage_size_gib: 256, ha_type: "async")

      expect(postgres_resource.reload).to have_attributes(target_vm_size: "standard-8", target_storage_size_gib: 256, ha_type: "async", user_config: {"ubicloud.shared_memory_percent" => "50"})
      expect(replica.reload).to have_attributes(target_vm_size: "standard-8", target_storage_size_gib: 256, user_config: {"work_mem" => "32MB"})
    end

    it "clears ignore_instance_size_mismatch on all servers only when target_vm_size changes" do
      servers = [postgres_resource, replica].map do |resource|
        server = PostgresServer.create(
          timeline:, resource_id: resource.id, vm_id: create_hosted_vm(project, private_subnet, "pg-vm-#{resource.name}").id,
          is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17",
        )
        Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
        server.incr_ignore_instance_size_mismatch
        server
      end
      semaphores = Semaphore.where(strand_id: servers.map(&:id), name: "ignore_instance_size_mismatch")

      postgres_resource.update_target_sizes_with_replicas(target_vm_size: postgres_resource.target_vm_size, target_storage_size_gib: 256)
      expect(semaphores.count).to eq 2

      postgres_resource.update_target_sizes_with_replicas(target_vm_size: "standard-8", target_storage_size_gib: 256)
      expect(semaphores.all).to eq []
    end

    it "clamps ubicloud.shared_memory_percent on self and replicas when scaling down" do
      # standard-8 is 32 GiB, so 75 is allowed; standard-4 is 16 GiB, where the
      # ceiling drops to 50.
      postgres_resource.update(target_vm_size: "standard-8", user_config: {"ubicloud.shared_memory_percent" => "75", "work_mem" => "32MB"})
      replica.update(user_config: {"ubicloud.shared_memory_percent" => "60"})

      postgres_resource.update_target_sizes_with_replicas(target_vm_size: "standard-4", target_storage_size_gib: 256)

      expect(postgres_resource.reload.user_config).to eq({"ubicloud.shared_memory_percent" => "50", "work_mem" => "32MB"})
      expect(replica.reload.user_config).to eq({"ubicloud.shared_memory_percent" => "50"})
    end
  end

  describe "#provision_new_standby" do
    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(project.id)
    end

    let(:vm1) { create_hosted_vm(project, private_subnet, "pg-vm-1") }
    let(:vm2) { create_hosted_vm(project, private_subnet, "pg-vm-2") }
    let(:ps1) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm1.id, is_representative: true,
        synchronization_status: "ready", timeline_access: "push", version: postgres_resource.target_version)
    }
    let(:ps2) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm2.id,
        synchronization_status: "ready", timeline_access: "fetch", version: postgres_resource.target_version)
    }

    def new_server
      PostgresServer.exclude(id: [ps1.id, ps2.id]).first
    end

    def prepare_servers
      [ps1, ps2].each do |server|
        VmStorageVolume.create(vm_id: server.vm_id, size_gib: postgres_resource.target_storage_size_gib, boot: false, disk_index: 0)
        Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
      end
    end

    it "provisions a fetch standby on the existing timeline without excluding hosts when Config.allow_unspread_servers is true" do
      ps1
      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_data_centers: [])).and_call_original

      expect { postgres_resource.provision_new_standby }.to change(PostgresServer, :count).from(1).to(2).and not_change(PostgresTimeline, :count)
      expect(new_server).to have_attributes(resource_id: postgres_resource.id, timeline_id: timeline.id, timeline_access: "fetch")
      expect(new_server.vm.vm_firewalls).to eq([postgres_resource.internal_firewall])
      expect(new_server.vm.strand.stack[0].values_at("exclude_data_centers", "exclude_host_ids")).to eq([[], []])
    end

    it "provisions a new server on the parent's timeline for a read replica" do
      ps1
      parent = described_class.create(
        name: "pg-parent", superuser_password: "dummy-password", ha_type: "none", target_version: "17", location_id:, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2", target_storage_size_gib: 64,
      )
      parent_timeline = create_postgres_timeline(location_id:)
      PostgresServer.create(timeline: parent_timeline, resource_id: parent.id, vm_id: create_hosted_vm(project, private_subnet, "pg-parent-vm").id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
      postgres_resource.update(parent_id: parent.id)

      expect { postgres_resource.provision_new_standby }.to change(PostgresServer, :count).from(2).to(3)
      expect(PostgresServer.where(resource_id: postgres_resource.id).exclude(id: ps1.id).get(:timeline_id)).to eq(parent_timeline.id)
    end

    describe "excludes only active server data centers" do
      before do
        allow(Config).to receive(:allow_unspread_servers).and_return(false)
        ps1
        ps2
        vm_host_1 = create_vm_host
        vm_host_1.update(data_center: "dc1")
        vm_host_2 = create_vm_host
        vm_host_2.update(data_center: "dc2")
        vm1.update(vm_host_id: vm_host_1.id)
        vm2.update(vm_host_id: vm_host_2.id)
        prepare_servers
      end

      it "excludes both data centers when both servers are active" do
        expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_data_centers: contain_exactly("dc1", "dc2"))).and_call_original
        postgres_resource.provision_new_standby
      end

      it "does not exclude data center of a server being recycled" do
        ps2.incr_recycle
        expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_data_centers: ["dc1"])).and_call_original
        postgres_resource.provision_new_standby
      end

      it "does not exclude data center of a server being destroyed" do
        ps2.incr_destroy
        expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_data_centers: ["dc1"])).and_call_original
        postgres_resource.provision_new_standby
      end
    end

    it "provisions a new server excluding the representative server's host for leaseweb" do
      expect(Config).to receive(:allow_unspread_servers).and_return(false)
      expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::LEASEWEB_PROVIDER_NAME).at_least(:once)
      ps1
      vm_host = create_vm_host
      vm1.update(vm_host_id: vm_host.id)

      expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_host_ids: [vm_host.id])).and_call_original

      postgres_resource.provision_new_standby
      expect(new_server.vm.strand.stack[0]["exclude_host_ids"]).to eq([vm_host.id])
    end

    describe "on AWS" do
      before do
        expect(postgres_resource.location).to receive(:provider).and_return(HostProvider::AWS_PROVIDER_NAME).at_least(:once)
        ps1
        ps2
        NicAwsResource.create_with_id(vm1.user_nic.id, subnet_az: "a")
        NicAwsResource.create_with_id(vm2.user_nic.id, subnet_az: "b")
        prepare_servers
      end

      it "provisions a new server in the az of the representative server if use_different_az is not set" do
        expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(availability_zone: "a")).and_call_original
        postgres_resource.provision_new_standby
        expect(new_server.vm.user_nic.strand.stack[0]["availability_zone"]).to eq("a")
      end

      it "aims a new server at the preferred az rather than following the representative server" do
        LocationAz.create(location_id:, az: "c", zone_id: "usw2-az3")
        postgres_resource.update(preferred_availability_zone_id: "usw2-az3")
        expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble)
          .with(hash_including(availability_zone: "c", exclude_availability_zones: [])).and_call_original
        postgres_resource.provision_new_standby
        expect(new_server.vm.user_nic.strand.stack[0]["availability_zone"]).to eq("c")
      end

      describe "with use_different_az set" do
        before { postgres_resource.incr_use_different_az }

        it "excludes the AZs of active servers" do
          expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_availability_zones: contain_exactly("a", "b"))).and_call_original
          postgres_resource.provision_new_standby
          stack = new_server.vm.strand.stack[0]
          expect([stack["unsupported_azs"].sort, stack["exclude_availability_zones"]]).to eq([["a", "b"], []])
        end

        it "does not exclude AZ of a server being recycled" do
          ps2.incr_recycle
          expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_availability_zones: ["a"])).and_call_original
          postgres_resource.provision_new_standby
        end

        it "does not exclude AZ of a server being destroyed" do
          ps2.incr_destroy
          expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble).with(hash_including(exclude_availability_zones: ["a"])).and_call_original
          postgres_resource.provision_new_standby
        end
      end

      describe "with a requested availability zone" do
        before do
          LocationAz.create(location_id:, az: "a", zone_id: "usw2-az1")
          LocationAz.create(location_id:, az: "b", zone_id: "usw2-az2")
          LocationAz.create(location_id:, az: "c", zone_id: "usw2-az3")
          postgres_resource.incr_use_different_az
        end

        it "pins new servers to the zone the required id names, spread or not" do
          postgres_resource.update(required_availability_zone_id: "usw2-az1")
          expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble)
            .with(hash_including(availability_zone: "a", availability_zone_required: true, exclude_availability_zones: [])).and_call_original
          postgres_resource.provision_new_standby
          expect(new_server.vm.strand.stack[0]["required_availability_zone"]).to eq("a")
        end

        it "prefers the zone the preferred id names while still excluding the azs in use" do
          postgres_resource.update(preferred_availability_zone_id: "usw2-az3")
          expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble)
            .with(hash_including(availability_zone: "c", availability_zone_required: false, exclude_availability_zones: contain_exactly("a", "b"))).and_call_original
          postgres_resource.provision_new_standby
          expect(new_server.vm.strand.stack[0]["required_availability_zone"]).to be_nil
        end

        it "drops the preferred zone when a server already occupies it, or when the location does not have it" do
          expect(Prog::Postgres::PostgresServerNexus).to receive(:assemble)
            .with(hash_including(availability_zone: nil, exclude_availability_zones: contain_exactly("a", "b"))).and_call_original.twice
          postgres_resource.update(preferred_availability_zone_id: "usw2-az2")
          postgres_resource.provision_new_standby
          postgres_resource.update(preferred_availability_zone_id: "usw2-az9")
          postgres_resource.provision_new_standby
        end

        it "refuses to place a server when the location does not have the required zone id" do
          postgres_resource.update(required_availability_zone_id: "usw2-az9")
          expect {
            postgres_resource.provision_new_standby
          }.to raise_error RuntimeError, "#{postgres_resource.location.name} has no availability zone usw2-az9"
        end
      end
    end
  end

  describe "family image migration" do
    def create_family_server(name:, image_family:, is_representative:, ready: true)
      vm = create_hosted_vm(project, private_subnet, name)
      server = PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative:, synchronization_status: "ready",
        timeline_access: is_representative ? "push" : "fetch", version: "17", image_family:)
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: ready ? "wait" : "start")
      server
    end

    it "#family_migration_in_progress? is true while the representative runs a different family" do
      create_family_server(name: "pg-rep", image_family: "ubuntu-2204", is_representative: true)
      postgres_resource.update(target_image_family: "ubuntu-2604")
      expect(postgres_resource.reload.family_migration_in_progress?).to be(true)
    end

    it "#family_migration_in_progress? is false once the representative runs the target family" do
      create_family_server(name: "pg-rep", image_family: "ubuntu-2604", is_representative: true)
      postgres_resource.update(target_image_family: "ubuntu-2604")
      expect(postgres_resource.reload.family_migration_in_progress?).to be(false)
    end

    it "#family_migration_in_progress? is false for a read replica" do
      create_family_server(name: "pg-rep", image_family: "ubuntu-2204", is_representative: true)
      parent = create_postgres_resource(project:, location_id:)
      postgres_resource.update(parent_id: parent.id, target_image_family: "ubuntu-2604")
      expect(postgres_resource.reload.family_migration_in_progress?).to be(false)
    end

    it "#family_migration_candidate returns the newest target-family standby" do
      create_family_server(name: "pg-rep", image_family: "ubuntu-2204", is_representative: true)
      postgres_resource.update(target_image_family: "ubuntu-2604")
      candidate = create_family_server(name: "pg-cand", image_family: "ubuntu-2604", is_representative: false)
      expect(postgres_resource.reload.family_migration_candidate).to eq(candidate)
    end

    it "gates convergence on a single fresh, ready candidate during the migration" do
      create_family_server(name: "pg-rep", image_family: "ubuntu-2204", is_representative: true)
      postgres_resource.update(target_image_family: "ubuntu-2604")
      expect(postgres_resource.reload.has_enough_fresh_servers?).to be(false)
      expect(postgres_resource.has_enough_ready_servers?).to be(false)

      create_family_server(name: "pg-cand", image_family: "ubuntu-2604", is_representative: false)
      expect(postgres_resource.reload.has_enough_fresh_servers?).to be(true)
      expect(postgres_resource.has_enough_ready_servers?).to be(true)
    end
  end

  describe "#upgrade_candidate_server" do
    let(:vm_host) { create_vm_host }
    let(:storage_device) {
      StorageDevice.create(
        name: "nvme0", vm_host_id: vm_host.id,
        total_storage_gib: 100, available_storage_gib: 80,
      )
    }

    def create_server_with_boot_image(boot_image_version:, is_representative: false, created_offset: 0)
      vm = create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}")
      boot_image = BootImage.create(
        name: "postgres-ubuntu-#{SecureRandom.hex(4)}", version: boot_image_version,
        vm_host_id: vm_host.id, activated_at: Time.now, size_gib: 10,
      )
      VmStorageVolume.create(
        vm_id: vm.id, boot: true, size_gib: 64, disk_index: 0,
        storage_device_id: storage_device.id, boot_image_id: boot_image.id,
      )
      PostgresServer.create(
        timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative:,
        created_at: Time.now + created_offset,
        synchronization_status: "ready", timeline_access: "push", version: "17",
      )
    end

    it "returns the newest standby with a boot image that supports the target version when location is not aws" do
      create_server_with_boot_image(boot_image_version: "20240801", is_representative: true)
      create_server_with_boot_image(boot_image_version: "20240729", created_offset: 3600)
      expect(postgres_resource.upgrade_candidate_server).to be_nil

      create_server_with_boot_image(boot_image_version: "20240801", created_offset: -3600)
      standby = create_server_with_boot_image(boot_image_version: "20240801", created_offset: 0)
      expect(postgres_resource.reload.upgrade_candidate_server).to eq(standby)
    end

    it "returns candidate when available and location is aws" do
      # Create AWS location
      aws_location = Location.create(
        name: "us-west-2", provider: "aws", display_name: "aws-us-west-2",
        ui_name: "AWS US West 2", visible: true,
      )
      aws_subnet = PrivateSubnet.create(
        name: "aws-subnet", project_id: project.id, location_id: aws_location.id,
        net4: "172.0.1.0/26", net6: "fdfa:b5aa:14a3:4a3e::/64",
      )
      aws_timeline = create_postgres_timeline(location_id: aws_location.id)
      aws_resource = described_class.create(
        name: "pg-aws", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id: aws_location.id, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
        target_storage_size_gib: 64,
      )

      # Create VMs with AWS boot images
      vm1 = Prog::Vm::Nexus.assemble_with_sshable(
        project.id, name: "aws-vm-1", private_subnet_id: aws_subnet.id,
        location_id: aws_location.id, unix_user: "ubi", boot_image: "ami-12345678",
      ).subject

      vm2 = Prog::Vm::Nexus.assemble_with_sshable(
        project.id, name: "aws-vm-2", private_subnet_id: aws_subnet.id,
        location_id: aws_location.id, unix_user: "ubi", boot_image: "ami-87654321",
      ).subject

      vm3 = Prog::Vm::Nexus.assemble_with_sshable(
        project.id, name: "aws-vm-3", private_subnet_id: aws_subnet.id,
        location_id: aws_location.id, unix_user: "ubi", boot_image: "ami-primary",
      ).subject

      # Create PgAwsAmi for the first AMI only
      PgAwsAmi.create(aws_ami_id: "ami-12345678", arch: "x64")

      # Primary
      PostgresServer.create(
        timeline: aws_timeline, resource_id: aws_resource.id, vm_id: vm3.id,
        is_representative: true, synchronization_status: "ready",
        timeline_access: "push", version: "17",
      )
      # Standby with valid AMI (older)
      standby1 = PostgresServer.create(
        timeline: aws_timeline, resource_id: aws_resource.id, vm_id: vm1.id,
        is_representative: false, created_at: Time.now - 3600,
        synchronization_status: "ready", timeline_access: "push", version: "17",
      )
      # Standby with invalid AMI (newer)
      PostgresServer.create(
        timeline: aws_timeline, resource_id: aws_resource.id, vm_id: vm2.id,
        is_representative: false, created_at: Time.now,
        synchronization_status: "ready", timeline_access: "push", version: "17",
      )

      expect(aws_resource.upgrade_candidate_server).to eq(standby1)
    end
  end

  describe "#lockout_mechanisms" do
    it "returns pg_stop, hba, and host_routing for metal resources" do
      expect(postgres_resource.lockout_mechanisms).to eq(["pg_stop", "hba", "host_routing"])
    end

    it "returns pg_stop, hba, and detach_nic for AWS resources" do
      aws_location = Location.create(
        name: "us-east-1-lockout", provider: "aws", display_name: "aws",
        ui_name: "aws", visible: true,
      )
      aws_resource = described_class.create(
        name: "pg-aws-lockout", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id: aws_location.id, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
        target_storage_size_gib: 64,
      )
      expect(aws_resource.lockout_mechanisms).to eq(["pg_stop", "hba", "detach_nic"])
    end
  end

  describe ".default_version" do
    it "returns the default version, which the standard flavor must offer" do
      expect(Option::POSTGRES_VERSION_OPTIONS[PostgresResource::Flavor::STANDARD]).to include(PostgresResource::DEFAULT_VERSION)
      expect(described_class.default_version).to eq(PostgresResource::DEFAULT_VERSION)
    end
  end

  describe "#boot_image" do
    it "returns the metal image for the image family" do
      expect(postgres_resource.boot_image("16", "x64", "ubuntu-2204")).to eq("postgres-ubuntu-2204")
    end

    it "delegates to the location's pg_aws_ami for AWS resources" do
      aws_location = Location.create(
        name: "us-west-2-boot-image", provider: "aws", display_name: "aws",
        ui_name: "aws", visible: true,
      )
      aws_resource = described_class.create(
        name: "pg-aws-boot-image", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id: aws_location.id, project_id: project.id,
        user_config: {}, pgbouncer_user_config: {}, target_vm_size: "standard-2",
        target_storage_size_gib: 64,
      )
      PgAwsAmi.create(aws_location_name: aws_location.name, aws_ami_id: "ami-12345678", pg_version: "17", arch: "x64")
      PgAwsAmi.create(aws_location_name: aws_location.name, aws_ami_id: "ami-2604abcd", pg_version: "17", arch: "x64", family: "ubuntu-2604")

      expect(aws_resource.boot_image("17", "x64", "ubuntu-2204")).to eq("ami-12345678")
      expect(aws_resource.boot_image("17", "x64", "ubuntu-2604")).to eq("ami-2604abcd")
    end
  end

  describe "convergence checks" do
    let(:storage_device) { StorageDevice.create(name: "nvme0", vm_host_id: create_vm_host.id, total_storage_gib: 100, available_storage_gib: 80) }

    def create_server(version: "17", is_representative: false, label: "wait", boot_image_version: nil)
      vm = create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}")
      VmStorageVolume.create(vm_id: vm.id, boot: false, size_gib: 64, disk_index: 1, storage_device_id: storage_device.id)
      if boot_image_version
        boot_image = BootImage.create(name: "postgres-ubuntu-#{SecureRandom.hex(4)}", version: boot_image_version, vm_host_id: storage_device.vm_host_id, activated_at: Time.now, size_gib: 10)
        VmStorageVolume.create(vm_id: vm.id, boot: true, size_gib: 64, disk_index: 0, storage_device_id: storage_device.id, boot_image_id: boot_image.id)
      end
      server = PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id, is_representative:,
        synchronization_status: "ready", timeline_access: is_representative ? "push" : "fetch", version:)
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label:)
      server
    end

    def convergence_state
      postgres_resource.reload
      [postgres_resource.has_enough_fresh_servers?, postgres_resource.has_enough_ready_servers?, postgres_resource.needs_convergence?]
    end

    it "counts fresh and ready servers against the HA type when not upgrading" do
      create_server(is_representative: true)
      expect(convergence_state).to eq [true, true, false]
      postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
      expect(convergence_state).to eq [false, false, true]
    end

    it "needs convergence when a server needs recycling" do
      create_server(is_representative: true).incr_recycle
      expect(convergence_state).to eq [false, false, true]
    end

    it "requires a fresh and ready upgrade candidate while upgrading" do
      create_server(version: "16", is_representative: true)
      expect(convergence_state).to eq [false, false, true]

      candidate = create_server(label: "wait_bootstrap_rhizome", boot_image_version: "20240801")
      expect(convergence_state).to eq [true, false, true]

      candidate.strand.update(label: "wait")
      expect(convergence_state).to eq [true, true, true]
    end
  end

  it "needs_sync_replication? is true only for sync HA" do
    postgres_resource.update(ha_type: PostgresResource::HaType::SYNC)
    expect(postgres_resource.needs_sync_replication?).to be(true)
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.needs_sync_replication?).to be(false)
    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.needs_sync_replication?).to be(false)
  end

  describe "#target_storage_capacity_gib" do
    it "converts AWS instance-store capacity from decimal GB to binary GiB" do
      aws_location = Location.create(name: "us-east-1", provider: "aws", display_name: "aws-us-east-1", ui_name: "aws-us-east-1", visible: true)
      resource = create_postgres_resource(project:, location_id: aws_location.id)
      resource.update(target_storage_size_gib: 937)
      expect(resource.target_storage_capacity_gib).to be_within(0.01).of(872.65)
    end

    it "leaves metal storage sizes as binary GiB" do
      postgres_resource.update(target_storage_size_gib: 937)
      expect(postgres_resource.target_storage_capacity_gib).to eq(937.0)
    end
  end

  describe "#latest_backup_too_large_for_target?" do
    before do
      create_postgres_server(resource: postgres_resource, timeline:)
      postgres_resource.update(target_storage_size_gib: 256)
    end

    it "returns true when latest backup size exceeds target" do
      timeline.update(latest_backup_size_in_gib: 1024)
      expect(postgres_resource.latest_backup_too_large_for_target?).to be(true)
    end

    it "returns false when latest backup size fits target" do
      timeline.update(latest_backup_size_in_gib: 100)
      expect(postgres_resource.latest_backup_too_large_for_target?).to be(false)
    end

    it "applies the scale-down headroom only when shrinking storage" do
      timeline.update(latest_backup_size_in_gib: 205)

      # Same size, so no headroom and 205 still fits 256.
      same_size = create_postgres_resource(project:, location_id:)
      same_size.update(target_storage_size_gib: 256)
      create_postgres_server(resource: same_size, timeline:)
      expect(same_size.latest_backup_too_large_for_target?).to be(false)

      # Shrinking 512 to 256, so 205 exceeds the 256 * 0.8 = 204.8 threshold.
      shrinking = create_postgres_resource(project:, location_id:)
      shrinking.update(target_storage_size_gib: 512)
      create_postgres_server(resource: shrinking, timeline:)
      shrinking.update(target_storage_size_gib: 256)
      expect(shrinking.latest_backup_too_large_for_target?).to be(true)
    end

    it "treats a resource with no server yet as initial provisioning" do
      parent = create_postgres_resource(project:, location_id:)
      parent.update(target_storage_size_gib: 256)
      create_postgres_server(resource: parent, timeline:)
      timeline.update(latest_backup_size_in_gib: 205)

      replica = create_postgres_resource(project:, location_id:)
      replica.update(parent_id: parent.id, target_storage_size_gib: 256)
      expect(replica.latest_backup_too_large_for_target?).to be(false)
    end

    it "compares against the binary-GiB filesystem for AWS storage" do
      aws_location = Location.create(name: "us-east-1", provider: "aws", display_name: "aws-us-east-1", ui_name: "aws-us-east-1", visible: true)
      LocationCredentialAws.create_with_id(aws_location, access_key: "k", secret_key: "s")
      LocationAz.create(location_id: aws_location.id, az: "a", zone_id: "usw2-az1")
      aws_timeline = create_postgres_timeline(location_id: aws_location.id)
      resource = create_postgres_resource(project:, location_id: aws_location.id)
      resource.update(target_storage_size_gib: 1875)
      create_postgres_server(resource:, timeline: aws_timeline)
      resource.update(target_storage_size_gib: 937)

      # 720 exceeds the converted 872.65 * 0.8 = 698.1 threshold but fits the raw
      # 937 * 0.8 = 749.6 one, so it only trips after conversion.
      aws_timeline.update(latest_backup_size_in_gib: 720)
      expect(described_class[resource.id].latest_backup_too_large_for_target?).to be(true)
      aws_timeline.update(latest_backup_size_in_gib: 600)
      expect(described_class[resource.id].latest_backup_too_large_for_target?).to be(false)
    end

    it "consults the parent's timeline for read replicas" do
      parent_timeline = create_postgres_timeline(location_id:)
      parent_timeline.update(latest_backup_size_in_gib: 1024)
      parent_resource = create_postgres_resource(project:, location_id:)
      create_postgres_server(resource: parent_resource, timeline: parent_timeline)
      postgres_resource.update(parent_id: parent_resource.id)

      expect(postgres_resource.latest_backup_too_large_for_target?).to be(true)
    end
  end

  it "#pg_firewall_rules returns empty array when there is no customer firewall" do
    # Set up private_subnet so customer_firewall query works (returns nil since no matching firewall)
    postgres_resource.update(private_subnet_id: private_subnet.id)
    expect(postgres_resource.pg_firewall_rules).to eq []
  end

  describe "display_state" do
    def create_representative_server(strand_label:)
      vm = create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}")
      server = PostgresServer.create(
        timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready",
        timeline_access: "push", version: "17",
      )
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: strand_label)
      server
    end

    it "returns 'deleting' when destroy or destroying semaphore is set" do
      postgres_resource.incr_destroy
      expect(postgres_resource.display_state).to eq("deleting")
      postgres_resource.decr_destroy
      postgres_resource.incr_destroying
      expect(postgres_resource.reload.display_state).to eq("deleting")
    end

    it "maps the representative server's strand label to a display state" do
      server = create_representative_server(strand_label: "wait")
      states = %w[unavailable initialize_database_from_backup wait_catch_up wait_synchronization wait_recovery_completion wait].to_h do |label|
        server.strand.update(label:)
        [label, postgres_resource.reload.display_state]
      end
      expect(states).to eq(
        "unavailable" => "unavailable",
        "initialize_database_from_backup" => "restoring_backup",
        "wait_catch_up" => "replaying_wal",
        "wait_synchronization" => "replaying_wal",
        "wait_recovery_completion" => "finalizing_restore",
        "wait" => "running",
      )
    end

    it "returns 'restarting' while the representative server has a restart pending" do
      create_representative_server(strand_label: "wait")
      postgres_resource.representative_server.incr_restart
      expect(postgres_resource.display_state).to eq("restarting")
    end

    it "returns 'running' only for running resource strand labels while the representative server waits" do
      create_representative_server(strand_label: "wait")
      states = %w[wait_refresh_public_cert wait_server].to_h do |label|
        postgres_resource.strand.update(label:)
        [label, postgres_resource.display_state]
      end
      expect(states).to eq("wait_refresh_public_cert" => "running", "wait_server" => "creating")
    end
  end

  it "returns in_maintenance_window? correctly" do
    # nil maintenance_window means always in maintenance window
    postgres_resource.update(maintenance_window_start_at: nil)
    expect(postgres_resource.in_maintenance_window?).to be(true)

    # With specific window hour, test time-based logic
    postgres_resource.update(maintenance_window_start_at: 1)
    expect(Time).to receive(:now).and_return(Time.utc(2025, 5, 1, 2), Time.utc(2025, 5, 1, 4), Time.utc(2025, 5, 1, 0))
    expect(postgres_resource.in_maintenance_window?).to be(true)
    expect(postgres_resource.in_maintenance_window?).to be(false)
    expect(postgres_resource.in_maintenance_window?).to be(false)
  end

  it "checks the enabled days of the maintenance window, by the day the window opened" do
    # 2025-05-01 is a Thursday (bit index 3 in DAYS_OF_WEEK). A 23:00-01:00
    # window enabled only on Thursday still covers Friday 00:30.
    cases = [
      [10, 1 << 3, Time.utc(2025, 5, 1, 10, 30), true],
      [10, 1 << 0, Time.utc(2025, 5, 1, 10, 30), false],
      [10, 0, Time.utc(2025, 5, 1, 10, 30), true],
      [10, 1 << 3, Time.utc(2025, 5, 1, 13), false],
      [23, 1 << 3, Time.utc(2025, 5, 2, 0, 30), true],
    ]
    expect(Time).to receive(:now).and_return(*cases.map { it[2] })
    expect(cases.map { |start_at, bitmask, _|
      postgres_resource.set(maintenance_window_start_at: start_at, maintenance_window_days_bitmask: bitmask)
      postgres_resource.in_maintenance_window?
    }).to eq(cases.map(&:last))
  end

  it "converts day names to and from the bitmask" do
    expect(described_class.maintenance_window_days_mask(nil)).to eq(0)
    expect(described_class.maintenance_window_days_mask([])).to eq(0)

    mask = described_class.maintenance_window_days_mask(["mon", "Wed", "fri"])
    expect(mask).to eq((1 << 0) | (1 << 2) | (1 << 4))

    postgres_resource.update(maintenance_window_days_bitmask: mask)
    expect(postgres_resource.maintenance_window_day_names).to eq(["mon", "wed", "fri"])

    postgres_resource.update(maintenance_window_days_bitmask: 0)
    expect(postgres_resource.maintenance_window_day_names).to eq([])
  end

  it "raises on an invalid day name" do
    expect { described_class.maintenance_window_days_mask(["funday"]) }.to raise_error(Validation::ValidationFailed, /maintenance_window_days/)
  end

  it "checks whether a storage size fits the observed disk usage" do
    # A scale down needs the usage to stay below 80% of the requested size.
    expect(postgres_resource.storage_size_fits_usage?(128, 102.4)).to be(true)
    expect(postgres_resource.storage_size_fits_usage?(128, 102.5)).to be(false)
  end

  it "labels the maintenance window" do
    expect(postgres_resource.maintenance_window_label).to be_nil

    postgres_resource.update(maintenance_window_start_at: 22)
    expect(postgres_resource.maintenance_window_label).to eq("22:00 - 00:00 (UTC)")

    postgres_resource.update(maintenance_window_days_bitmask: described_class.maintenance_window_days_mask(["mon", "thu"]))
    expect(postgres_resource.maintenance_window_label).to eq("Mon, Thu, 22:00 - 00:00 (UTC)")
  end

  it "#pending_platform_maintenance? is true only when a server is marked for a platform recycle" do
    server = PostgresServer.create(
      timeline:, resource_id: postgres_resource.id, vm_id: create_hosted_vm(project, private_subnet, "pg-vm").id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17",
    )
    Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
    expect(postgres_resource.pending_platform_maintenance?).to be(false)

    # A customer-initiated major version upgrade and system-health recycles
    # are not platform maintenance.
    postgres_resource.update(target_version: "18")
    server.incr_recycle_lagging_read_replica
    server.incr_recycle_unavailable_server
    expect(postgres_resource.pending_platform_maintenance?).to be(false)

    server.incr_recycle
    expect(postgres_resource.pending_platform_maintenance?).to be(true)
  end

  it "returns target_standby_count correctly" do
    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.target_standby_count).to eq(0)
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.target_standby_count).to eq(1)
    postgres_resource.update(ha_type: PostgresResource::HaType::SYNC)
    expect(postgres_resource.target_standby_count).to eq(2)
  end

  it "returns target_server_count correctly" do
    postgres_resource.update(ha_type: PostgresResource::HaType::NONE)
    expect(postgres_resource.target_server_count).to eq(1)
    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.target_server_count).to eq(2)
    postgres_resource.update(ha_type: PostgresResource::HaType::SYNC)
    expect(postgres_resource.target_server_count).to eq(3)
  end

  describe "check_all_dns_records" do
    let(:dns_zone) { DnsZone.create(project_id: project.id, name: "pg.example.com") }

    it "returns empty array if the resource does not have a DNS zone" do
      expect(postgres_resource.check_all_dns_records).to eq []
    end

    it "returns empty array if the resource does not have a representative_server" do
      expect(Config).to receive(:postgres_service_project_id).and_return(project.id)
      expect(Config).to receive(:postgres_service_hostname_v3).and_return("pg.example.com")
      dns_zone
      expect(postgres_resource.check_all_dns_records).to eq []
    end

    context "with DNS zone" do
      before do
        allow(Config).to receive_messages(postgres_service_project_id: project.id, postgres_service_hostname_v3: "pg.example.com")
        dns_zone
        vm = create_hosted_vm(project, private_subnet, "pg-vm")
        PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id, is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
      end

      it "resolves using the expected DNS servers" do
        expect(DnsChecker).to receive(:open).with(contain_exactly("10.0.1.1", "10.0.2.2", "10.1.1.1", "10.1.2.2"))
        2.times do
          server = DnsServer.create(name: "ns#{it}.ubicloud.com")
          dns_zone.add_dns_server(server)
          vm1 = create_vm(name: "vm#{it}1")
          vm2 = create_vm(name: "vm#{it}2")
          add_ipv4_to_vm(vm1, "10.#{it}.1.1")
          add_ipv4_to_vm(vm2, "10.#{it}.2.2")
          server.add_vm(vm1)
          server.add_vm(vm2)
        end
        postgres_resource.check_all_dns_records
      end

      context "with representative server" do
        let(:checker) { DnsChecker::Checker.new(nil) }

        before do
          # Currently not needed for these specs, but in case an actual nameserver IP is needed later:
          # server = DnsServer.create(name: "ns#{it}.ubicloud.com")
          # dns_zone.add_dns_server(server)
          # vm = create_vm(name: "vm1")
          # add_ipv4_to_vm(vm, "10.0.1.1")
          # server.add_vm(vm)
          expect(DnsChecker::Checker).to receive(:new).and_return(checker)
          add_ipv4_to_vm(postgres_resource.representative_server.vm, "10.1.2.3")
          postgres_resource.representative_server.vm.update(ephemeral_net6: "fe80::/80")
        end

        it "resolves CNAME record for AWS databases" do
          location = Location.create(display_name: "a1", name: "a1", ui_name: "a1", visible: true, provider: "aws")
          postgres_resource.update(location_id: location.id)
          AwsInstance.create_with_id(postgres_resource.representative_server.vm.id, ipv4_dns_name: "foo")
          expect(checker).to receive(:check).with(:CNAME, postgres_resource.hostname, "foo.")
          expect(postgres_resource.check_all_dns_records).to eq []
        end

        it "resolves A and AAAA records for metal databases" do
          # AAAA not added by default, need to add it
          postgres_resource.dns_zone.insert_record(type: "AAAA", record_name: postgres_resource.hostname, data: "fe80::2", ttl: 30)

          expect(checker).to receive(:check).with(:A, postgres_resource.hostname, "10.1.2.3")
          expect(checker).to receive(:check).with(:AAAA, postgres_resource.hostname, "fe80::2")
          expect(checker).to receive(:check).with(:A, postgres_resource.private_hostname, postgres_resource.representative_server.vm.private_ipv4_string)
          expect(checker).to receive(:check).with(:AAAA, postgres_resource.private_hostname, postgres_resource.representative_server.vm.private_ipv6_string)
          expect(postgres_resource.check_all_dns_records).to eq []
        end

        it "does not attempt to resolve AAAA public record for old metal databases lacking one" do
          postgres_resource.update(created_at: Time.utc(2025))
          expect(checker).to receive(:check).with(:A, postgres_resource.hostname, "10.1.2.3")
          expect(checker).to receive(:check).with(:A, postgres_resource.private_hostname, postgres_resource.representative_server.vm.private_ipv4_string)
          expect(checker).to receive(:check).with(:AAAA, postgres_resource.private_hostname, postgres_resource.representative_server.vm.private_ipv6_string)
          expect(postgres_resource.check_all_dns_records).to eq []
        end

        it "returns failures" do
          location = Location.create(display_name: "a1", name: "a1", ui_name: "a1", visible: true, provider: "aws")
          postgres_resource.update(location_id: location.id)
          AwsInstance.create_with_id(postgres_resource.representative_server.vm.id, ipv4_dns_name: "foo")
          expect(checker).to receive(:check) do |type, record_name, expected_value|
            checker.failures << {type:, record_name:, expected_value:, actual_value: "bar."}
          end
          expect(postgres_resource.check_all_dns_records).to eq [
            {type: :CNAME, record_name: postgres_resource.hostname, expected_value: "foo.", actual_value: "bar."},
          ]
        end
      end
    end
  end

  it "#ongoing_failover? is true while a server is taking over" do
    strands = Array.new(2) do
      server = PostgresServer.create(
        timeline:, resource_id: postgres_resource.id, vm_id: create_hosted_vm(project, private_subnet, "pg-vm-#{SecureRandom.hex(4)}").id,
        synchronization_status: "ready", timeline_access: "push", version: "17",
      )
      Strand.create_with_id(server, prog: "Postgres::PostgresServerNexus", label: "wait")
    end
    expect(postgres_resource.ongoing_failover?).to be false
    strands.first.update(label: "taking_over")
    expect(postgres_resource.reload.ongoing_failover?).to be true
  end

  it "#hostname_suffix returns the default hostname suffix of the hostname version if project is nil" do
    postgres_resource.project_id = nil
    expect(postgres_resource.hostname_suffix).to eq(Config.postgres_service_hostname_v3)
    postgres_resource.hostname_version = "v2"
    expect(postgres_resource.hostname_suffix).to eq(Config.postgres_service_hostname)
  end

  describe "\#{,cert_}{,private_}hostname" do
    it "uses IPv4 representative server address for no dns zone" do
      vm = create_hosted_vm(project, private_subnet, "pg-vm")
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id, is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
      AssignedVmAddress.create(dst_vm_id: vm.id, ip: "1.2.3.4/32")
      expect(postgres_resource.hostname).to eq "1.2.3.4"
      expect(postgres_resource.private_hostname).to eq postgres_resource.representative_server.vm.private_ipv4_string
      expect(postgres_resource.cert_hostname).to eq "1.2.3.4"
      expect(postgres_resource.cert_private_hostname).to eq postgres_resource.representative_server.vm.private_ipv4_string
    end

    it "with dns zone, handles hostname version v1/v2/v3" do
      expect(Config).to receive(:postgres_service_project_id).and_return(project.id).at_least(:once)
      DnsZone.create(project_id: project.id, name: Config.postgres_service_hostname)

      postgres_resource.hostname_version = "v1"
      expect(postgres_resource.hostname).to eq "pg-name.postgres.ubicloud.com"
      expect(postgres_resource.private_hostname).to eq "private.pg-name.postgres.ubicloud.com"
      expect(postgres_resource.cert_hostname).to eq "pg-name.postgres.ubicloud.com"
      expect(postgres_resource.cert_private_hostname).to eq "private.pg-name.postgres.ubicloud.com"

      postgres_resource.hostname_version = "v2"
      expect(postgres_resource.hostname).to eq "pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com"
      expect(postgres_resource.private_hostname).to eq "private.pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com"
      expect(postgres_resource.cert_hostname).to eq "pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com"
      expect(postgres_resource.cert_private_hostname).to eq "private.pg-name.#{postgres_resource.ubid}.postgres.ubicloud.com"

      postgres_resource.hostname_version = "v3"
      expect(postgres_resource.hostname).to eq "pg-name.#{postgres_resource.ubid}.pg.ubicloud.app"
      expect(postgres_resource.private_hostname).to eq "pg-name.#{postgres_resource.ubid}.private.pg.ubicloud.app"
      expect(postgres_resource.cert_hostname).to eq "*.#{postgres_resource.ubid}.pg.ubicloud.app"
      expect(postgres_resource.cert_private_hostname).to eq "*.#{postgres_resource.ubid}.private.pg.ubicloud.app"
    end
  end

  it "#upgrade_stage returns the label of an ongoing upgrade" do
    expect(postgres_resource.upgrade_stage).to be_nil
    Strand.create(prog: "Postgres::ConvergePostgresResource", label: "upgrade_standby", parent_id: postgres_resource.strand.id)
    expect(postgres_resource.reload.upgrade_stage).to eq("upgrade_standby")
  end

  describe "#upgrade_status" do
    it "returns failed if the postgres resource upgrade failed" do
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "upgrade_failed", parent_id: postgres_resource.strand.id)
      expect(postgres_resource.upgrade_status).to eq("failed")
    end

    it "returns not_running if the postgres resource does not need upgrade" do
      # Create representative server with matching version so version == target_version
      vm = create_hosted_vm(project, private_subnet, "pg-vm-no-upgrade")
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
      expect(postgres_resource.upgrade_status).to eq("not_running")
    end

    it "returns running if the postgres resource upgrade is in progress" do
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "upgrade_standby", parent_id: postgres_resource.strand.id)
      vm = create_hosted_vm(project, private_subnet, "pg-vm-upgrade")
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id, is_representative: true,
        synchronization_status: "ready", timeline_access: "push", version: "16")
      expect(postgres_resource.upgrade_status).to eq("running")
    end
  end

  it "#can_upgrade? is true unless the target version is the latest version" do
    postgres_resource.update(target_version: "16", flavor: PostgresResource::Flavor::STANDARD)
    expect(postgres_resource.can_upgrade?).to be true
    postgres_resource.update(target_version: PostgresResource::LATEST_VERSION)
    expect(postgres_resource.can_upgrade?).to be false
  end

  it "#ready_for_read_replica? requires a converged resource with a restorable backup" do
    vm = create_hosted_vm(project, private_subnet, "pg-vm")
    VmStorageVolume.create(vm:, boot: false, size_gib: 64, disk_index: 1)
    PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
      is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    expect(postgres_resource.ready_for_read_replica?).to be false

    timeline.update(cached_earliest_backup_at: Time.now - 3600)
    expect(postgres_resource.reload.ready_for_read_replica?).to be true

    postgres_resource.update(ha_type: PostgresResource::HaType::ASYNC)
    expect(postgres_resource.reload.ready_for_read_replica?).to be false
  end

  describe "#handle_storage_auto_scale" do
    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-auto-scale") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    before do
      VmStorageVolume.create(vm:, boot: false, size_gib: 64, disk_index: 1)
      server
      account = Account.create(email: "test@example.com")
      account.add_project(project)
      AccessControlEntry.create(project_id: project.id, subject_id: account.id, action_id: ActionType::NAME_MAP["Postgres:view"])
      account_with_no_access = Account.create(email: "test2@example.com")
      account_with_no_access.add_project(project)
      allow(Util).to receive(:send_email)
      allow(postgres_resource).to receive(:representative_server).and_return(server)
    end

    it "returns early and logs if disk usage check fails" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_raise(RuntimeError, "connection refused")
      expect(Clog).to receive(:emit).with("Failed to check disk usage for #{postgres_resource.ubid}, skipping storage auto-scale check", server)
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "clears semaphores when usage drops below 77% and no pages exist" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  70%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      postgres_resource.incr_storage_auto_scale_canceled

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_canceled").count).to eq(0)
    end

    it "clears semaphores and resolves pages when usage drops below 77%" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  70%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      postgres_resource.incr_storage_auto_scale_action_performed_85
      postgres_resource.incr_storage_auto_scale_action_performed_90

      Prog::PageNexus.assemble("test", ["PGStorageAutoScaleMaxSize", postgres_resource.id], postgres_resource.ubid, resource_id: postgres_resource.id)
      Prog::PageNexus.assemble("test", ["PGStorageAutoScaleQuotaInsufficient", postgres_resource.id], postgres_resource.ubid, resource_id: postgres_resource.id)
      Prog::PageNexus.assemble("test", ["PGStorageAutoScaleCanceled", postgres_resource.id], postgres_resource.ubid, resource_id: postgres_resource.id)

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_85").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_90").count).to eq(0)
      expect(Semaphore.where(strand_id: Page.from_tag_parts("PGStorageAutoScaleMaxSize", postgres_resource.id).id, name: "resolve").count).to eq(1)
      expect(Semaphore.where(strand_id: Page.from_tag_parts("PGStorageAutoScaleQuotaInsufficient", postgres_resource.id).id, name: "resolve").count).to eq(1)
      expect(Semaphore.where(strand_id: Page.from_tag_parts("PGStorageAutoScaleCanceled", postgres_resource.id).id, name: "resolve").count).to eq(1)
    end

    it "clears semaphores with hysteresis (3% below threshold)" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  78%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      postgres_resource.incr_storage_auto_scale_action_performed_85
      postgres_resource.incr_storage_auto_scale_action_performed_90

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_85").count).to eq(0)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_90").count).to eq(0)
    end

    it "returns early when usage < 80%" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  79%\n")
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "returns early when usage 80-84% and 80% action already set" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  83%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "returns early when usage 85-89% and 85% action already set" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  88%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_85
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "returns early when 90% action already set" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  95%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_90
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "does not duplicate semaphores that are already set" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")
      postgres_resource.incr_storage_auto_scale_action_performed_80
      postgres_resource.incr_storage_auto_scale_action_performed_85

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_85").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_90").count).to eq(1)
    end

    it "returns early when auto-scale is already in progress" do
      postgres_resource.update(target_storage_size_gib: 128)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")
      expect(postgres_resource).not_to receive(:next_storage_auto_scale_option)
      postgres_resource.handle_storage_auto_scale
    end

    it "sends warning email at 80-89% with next option available" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_80").count).to eq(1)
      expect(Semaphore.where(strand_id: postgres_resource.strand.id, name: "storage_auto_scale_action_performed_85").count).to eq(1)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Storage Warning: pg-name at 85% capacity",
        hash_including(body: array_including(/When disk usage reaches 90%, storage will be automatically increased/)),
      )
    end

    it "creates page and sends warning email at 80-89% when at max size" do
      server.vm.update(vcpus: 60, cpu_percent_limit: 6000)
      server.vm.vm_storage_volumes.find { !it.boot }.update(size_gib: 4096)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Page.from_tag_parts("PGStorageAutoScaleMaxSize", postgres_resource.id).resource_id).to eq(postgres_resource.id)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Storage Warning: pg-name at 85% capacity",
        hash_including(body: array_including(/However, your database has already reached the maximum available storage size, so auto-scaling cannot proceed./)),
      )
    end

    it "creates page and sends warning email at 80-89% when quota insufficient" do
      server.vm.update(vcpus: 16, cpu_percent_limit: 1600)
      server.vm.vm_storage_volumes.find { !it.boot }.update(size_gib: 2048)
      project.add_quota(quota_id: ProjectQuota.default_quotas["PostgresVCpu"]["id"], value: 16)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Page.from_tag_parts("PGStorageAutoScaleQuotaInsufficient", postgres_resource.id).resource_id).to eq(postgres_resource.id)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Storage Warning: pg-name at 85% capacity",
        hash_including(body: array_including(/However, your project does not have sufficient quota, so auto-scaling cannot proceed./)),
      )
    end

    it "triggers auto-scale at 90%+ with next option available and sufficient quota" do
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(postgres_resource.reload.target_vm_size).to eq("standard-2")
      expect(postgres_resource.target_storage_size_gib).to eq(128)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Auto-Scaling: pg-name",
        hash_including(body: array_including(/We are currently preparing a new server with increased storage./)),
      )
    end

    it "allows hobby instances to upgrade to standard family during auto-scale" do
      postgres_resource.update(target_vm_size: "hobby-2", target_storage_size_gib: 128)
      server.vm.update(family: "burstable", cpu_percent_limit: 100)
      server.vm.vm_storage_volumes.find { !it.boot }.update(size_gib: 128)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(postgres_resource.reload.target_vm_size).to eq("standard-2")
      expect(postgres_resource.target_storage_size_gib).to eq(256)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Auto-Scaling: pg-name",
        hash_including(body: array_including(/instance is being upgraded from hobby-2 to standard-2/)),
      )
    end

    it "still sends an email at 90%+ when at max size" do
      server.vm.update(vcpus: 60, cpu_percent_limit: 6000)
      server.vm.vm_storage_volumes.find { !it.boot }.update(size_gib: 4096)
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Auto-Scaling: pg-name",
        hash_including(body: array_including(/However, your database has already reached the maximum available storage size./)),
      )
    end

    it "sends warning at 80-89% when canceled" do
      postgres_resource.incr_storage_auto_scale_canceled
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  85%\n")

      postgres_resource.handle_storage_auto_scale

      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Storage Warning: pg-name at 85% capacity",
        hash_including(body: array_including(/you previously canceled auto-scaling/)),
      )
    end

    it "does not update targets at 90%+ when canceled but still sends email" do
      postgres_resource.incr_storage_auto_scale_canceled
      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(postgres_resource.reload.target_storage_size_gib).to eq(64)
      expect(Util).to have_received(:send_email).with(
        ["test@example.com"],
        "PostgreSQL Auto-Scaling: pg-name",
        hash_including(body: array_including(/you previously canceled auto-scaling/)),
      )
    end

    it "updates read replicas alongside the primary when auto-scaling" do
      read_replica = described_class.create(
        name: "pg-replica", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id:, project_id: project.id, user_config: {},
        pgbouncer_user_config: {}, target_vm_size: "standard-2", target_storage_size_gib: 64,
        parent_id: postgres_resource.id,
      )

      expect(server.vm.sshable).to receive(:_cmd).with("df --output=pcent /dat | tail -n 1").and_return("  92%\n")

      postgres_resource.handle_storage_auto_scale

      expect(read_replica.reload.target_vm_size).to eq("standard-2")
      expect(read_replica.reload.target_storage_size_gib).to eq(128)
    end
  end

  describe "#send_storage_auto_scale_warning_email" do
    before do
      Account.create(email: "user@example.com").add_project(project)
      allow(Util).to receive(:send_email)
      server
    end

    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-email") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    it "includes vm upgrade info when target size differs" do
      next_option = {"size" => "standard-4", "storage_size" => 256}
      postgres_resource.send_storage_auto_scale_warning_notification(85, next_option, nil)

      expect(Util).to have_received(:send_email) do |_recipients, _subject, **kwargs|
        expect(kwargs[:body].join("\n")).to include("instance will also be upgraded")
      end
    end

    it "includes read replica info when read replicas exist" do
      described_class.create(
        name: "pg-rr", superuser_password: "dummy-password", ha_type: "none",
        target_version: "17", location_id:, project_id: project.id, user_config: {},
        pgbouncer_user_config: {}, target_vm_size: "standard-2", target_storage_size_gib: 64,
        parent_id: postgres_resource.id,
      )

      next_option = {"size" => "standard-2", "storage_size" => 128}
      postgres_resource.send_storage_auto_scale_warning_notification(85, next_option, nil)

      expect(Util).to have_received(:send_email) do |_recipients, _subject, **kwargs|
        expect(kwargs[:body].join("\n")).to include("read replica(s)")
      end
    end
  end

  describe "#send_storage_auto_scale_started_email" do
    before do
      Account.create(email: "user@example.com").add_project(project)
      allow(Util).to receive(:send_email)
      server
    end

    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-started-email") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    it "includes vm upgrade info when target size differs" do
      next_option = {"size" => "standard-4", "storage_size" => 256}
      postgres_resource.send_storage_auto_scale_started_notification(92, next_option, nil)

      expect(Util).to have_received(:send_email) do |_recipients, _subject, **kwargs|
        expect(kwargs[:body].join("\n")).to include("instance is being upgraded")
      end
    end

    it "includes quota_insufficient info" do
      postgres_resource.send_storage_auto_scale_started_notification(92, nil, :quota_insufficient)

      expect(Util).to have_received(:send_email) do |_recipients, _subject, **kwargs|
        expect(kwargs[:body].join("\n")).to include("sufficient quota")
      end
    end
  end

  describe "#send_storage_auto_scale_canceled_email" do
    before do
      account = Account.create(email: "user@example.com")
      account.add_project(project)
      AccessControlEntry.create(project_id: project.id, subject_id: account.id, action_id: ActionType::NAME_MAP["Postgres:view"])
      account_with_no_access = Account.create(email: "user2@example.com")
      account_with_no_access.add_project(project)
      allow(Util).to receive(:send_email)
      server
    end

    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-canceled-email") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    it "sends email with canceled info including current storage and instance size" do
      postgres_resource.send_storage_auto_scale_canceled_notification

      expect(Util).to have_received(:send_email).with(
        ["user@example.com"],
        "PostgreSQL Auto-Scaling Canceled: pg-name",
        hash_including(
          greeting: "Hello,",
          body: array_including(/has been canceled as requested/),
        ),
      )
    end
  end

  describe "#send_failover_notification" do
    before do
      account = Account.create(email: "user@example.com")
      account.add_project(project)
      AccessControlEntry.create(project_id: project.id, subject_id: account.id, action_id: ActionType::NAME_MAP["Postgres:view"])
      account_with_no_access = Account.create(email: "user2@example.com")
      account_with_no_access.add_project(project)
      allow(Config).to receive(:postgres_notification_email).and_return("pg-notifications@example.com")
      allow(Util).to receive(:send_email)
    end

    it "tells accounts with access that a planned promotion briefly interrupts connections" do
      postgres_resource.send_failover_notification(mode: "planned")

      expect(Util).to have_received(:send_email).with(
        ["user@example.com"],
        "PostgreSQL Planned Maintenance: pg-name",
        hash_including(
          bcc: "pg-notifications@example.com",
          greeting: "Hello,",
          button_title: "View Database",
          button_link: "#{Config.base_url}#{project.path}#{postgres_resource.path}",
          body: array_including(
            /part of maintenance or a configuration change/,
            /Connections were briefly interrupted/,
          ),
        ),
      )
    end

    it "does not send an email for an unplanned promotion unless enabled" do
      postgres_resource.send_failover_notification(mode: "unplanned")

      expect(Util).not_to have_received(:send_email)
    end

    it "tells accounts with access that an unplanned promotion follows an unavailable primary when enabled" do
      expect(Config).to receive(:postgres_unplanned_failover_notification_enabled).and_return(true)
      postgres_resource.send_failover_notification(mode: "unplanned")

      expect(Util).to have_received(:send_email).with(
        ["user@example.com"],
        "PostgreSQL Failover: pg-name",
        hash_including(
          body: array_including(/primary server became unavailable/),
        ),
      )
    end
  end

  describe "#can_cancel_storage_auto_scale?" do
    it "returns false if canceled semaphore is already set or 90% action is not set" do
      # Neither set
      expect(postgres_resource.can_cancel_storage_auto_scale?).to be false

      # 90% set but canceled also set
      postgres_resource.incr_storage_auto_scale_action_performed_90
      postgres_resource.incr_storage_auto_scale_canceled
      expect(postgres_resource.can_cancel_storage_auto_scale?).to be false
    end

    it "returns false if no converge strand exists" do
      postgres_resource.incr_storage_auto_scale_action_performed_90
      expect(postgres_resource.can_cancel_storage_auto_scale?).to be false
    end

    it "returns false if converge strand label is not in allowed list" do
      postgres_resource.incr_storage_auto_scale_action_performed_90
      Strand.create(
        prog: "Postgres::ConvergePostgresResource",
        label: "recycle_representative_server",
        parent_id: postgres_resource.strand.id,
      )
      expect(postgres_resource.can_cancel_storage_auto_scale?).to be false
    end

    it "returns true when 90% action is set, not canceled, and converge strand is in an early label" do
      postgres_resource.incr_storage_auto_scale_action_performed_90
      %w[start provision_servers wait_servers_to_be_ready wait_for_maintenance_window].freeze.each do |label|
        Strand.dataset.where(prog: "Postgres::ConvergePostgresResource").destroy
        Strand.create(
          prog: "Postgres::ConvergePostgresResource",
          label:,
          parent_id: postgres_resource.strand.id,
        )
        expect(postgres_resource.can_cancel_storage_auto_scale?).to be(true), "expected true for label #{label}"
      end
    end
  end

  describe "#cancel_storage_auto_scale" do
    let(:vm) { create_hosted_vm(project, private_subnet, "pg-vm-cancel") }
    let(:server) {
      PostgresServer.create(timeline:, resource_id: postgres_resource.id, vm_id: vm.id,
        is_representative: true, synchronization_status: "ready", timeline_access: "push", version: "17")
    }

    before do
      VmStorageVolume.create(vm:, boot: false, size_gib: 64, disk_index: 1)
      server
      account = Account.create(email: "user@example.com")
      account.add_project(project)
      AccessControlEntry.create(project_id: project.id, subject_id: account.id, action_id: ActionType::NAME_MAP["Postgres:view"])
      account_with_no_access = Account.create(email: "user2@example.com")
      account_with_no_access.add_project(project)
      allow(Util).to receive(:send_email)
    end

    it "returns false if advisory lock cannot be acquired" do
      postgres_resource.incr_storage_auto_scale_action_performed_90
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "start", parent_id: postgres_resource.strand.id)

      expect(DB).to receive(:get).with(Sequel.function(:pg_try_advisory_xact_lock, postgres_resource.storage_auto_scale_lock_key)).and_return(false)
      expect(postgres_resource.cancel_storage_auto_scale).to be false
    end

    it "returns false if can_cancel_storage_auto_scale? is false" do
      # 90% action not set, so can_cancel returns false
      expect(postgres_resource.cancel_storage_auto_scale).to be false
    end

    it "resets targets, sets semaphore, creates page, sends email and returns true on success" do
      postgres_resource.update(target_vm_size: "standard-4", target_storage_size_gib: 256)
      postgres_resource.incr_storage_auto_scale_action_performed_90
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "provision_servers", parent_id: postgres_resource.strand.id)

      result = postgres_resource.cancel_storage_auto_scale

      expect(result).to be true
      postgres_resource.reload
      expect(postgres_resource.target_vm_size).to eq("standard-2")
      expect(postgres_resource.target_storage_size_gib).to eq(64)
      expect(postgres_resource.storage_auto_scale_canceled_set?).to be true
      expect(Page.from_tag_parts("PGStorageAutoScaleCanceled", postgres_resource.id).resource_id).to eq(postgres_resource.id)
      expect(Util).to have_received(:send_email).with(
        ["user@example.com"],
        "PostgreSQL Auto-Scaling Canceled: pg-name",
        hash_including(greeting: "Hello,"),
      )
    end

    it "also resets read replica targets on success" do
      read_replica = described_class.create(
        name: "pg-rr-cancel", superuser_password: "dummy", ha_type: "none",
        target_version: "17", location_id:, project_id: project.id, user_config: {},
        pgbouncer_user_config: {}, target_vm_size: "standard-4", target_storage_size_gib: 256,
        parent_id: postgres_resource.id,
      )
      postgres_resource.update(target_vm_size: "standard-4", target_storage_size_gib: 256)
      postgres_resource.incr_storage_auto_scale_action_performed_90
      Strand.create(prog: "Postgres::ConvergePostgresResource", label: "start", parent_id: postgres_resource.strand.id)

      postgres_resource.cancel_storage_auto_scale

      expect(read_replica.reload.target_vm_size).to eq("standard-2")
      expect(read_replica.reload.target_storage_size_gib).to eq(64)
    end
  end

  describe ".postgres_locations" do
    it "includes AWS public regions and the project's own BYOC locations" do
      byoc = Location.create(name: "p-byoc", display_name: "p-byoc", ui_name: "p-byoc", visible: false, provider: "aws", project_id: project.id)
      locations = described_class.postgres_locations(project)
      expect(locations.map(&:name)).to include("us-east-1", "us-west-2")
      expect(locations).to include(byoc)
    end

    it "includes gcp-us-central1 only when the project has it in visible_postgres_locations" do
      names = [nil, [], ["gcp-us-central1"]].map do |visible|
        project.set_ff_visible_postgres_locations(visible) if visible
        described_class.postgres_locations(project).map(&:name).include?("gcp-us-central1")
      end
      expect(names).to eq [false, false, true]
    end
  end

  describe ".generate_postgres_options" do
    let(:gcp_location) {
      Location.create(name: "gcp-us-central1", provider: "gcp", display_name: "us-central1", ui_name: "Iowa, US (GCP)", visible: false)
    }

    def gcp_family_names(project, location: gcp_location)
      option_tree, parents = described_class.generate_postgres_options(project, location: [location])
      OptionTreeGenerator.generate_allowed_options("family", option_tree, parents).map { it["family"] }.uniq
    end

    it "allows GCP families for GCP locations, as the project feature flags enable them" do
      family_names = gcp_family_names(project)
      expect(family_names).to include("c4a-standard", "c4a-highmem")
      expect(family_names & ["standard", "hobby", "m8gd", "z3-highlssd"]).to eq []

      project.set_ff_enable_z3_highlssd(true)
      project.set_ff_enable_c4a_standard(false)
      family_names = gcp_family_names(project)
      expect(family_names).to include("z3-highlssd", "c4a-highmem")
      expect(family_names).not_to include("c4a-standard")
    end

    it "does not offer a family in a location GCE does not have it in" do
      west3 = Location.create(name: "gcp-europe-west3", provider: "gcp", display_name: "europe-west3", ui_name: "Frankfurt, DE (GCP)", visible: false)
      project.set_ff_enable_c4d_standard(true)

      expect(gcp_family_names(project, location: west3)).not_to include("c4d-standard")
      expect(gcp_family_names(project)).to include("c4d-standard")
    end

    it "allows metal families for metal locations" do
      option_tree, parents = described_class.generate_postgres_options(project, location: [location])
      allowed_families = OptionTreeGenerator.generate_allowed_options("family", option_tree, parents)
      family_names = allowed_families.map { it["family"] }.uniq

      expect(family_names).to include("standard", "hobby")
      expect(family_names & Option::GCP_FAMILY_OPTIONS).to eq []
    end

    it "provides fixed storage sizes for GCP families, with two rungs for n2d sizes" do
      project.set_ff_enable_n2d_highmem(true)
      option_tree, parents = described_class.generate_postgres_options(project, location: [gcp_location])
      allowed_storage = OptionTreeGenerator.generate_allowed_options("storage_size", option_tree, parents)
      storage_sizes = ->(size) { allowed_storage.select { it["size"] == size }.map { it["storage_size"] } }

      expect([storage_sizes["c4a-standard-8"], storage_sizes["c4a-highmem-72"], storage_sizes["n2d-highmem-8"]]).to eq([[750], [6000], [3000, 6000]])
      expect(allowed_storage.map { it["size"] }).not_to include("n2d-standard-8")
    end

    describe "AWS 48xlarge sizes" do
      let(:aws_location) {
        Location.create(name: "us-east-2", provider: "aws", display_name: "aws-us-east-2", ui_name: "Ohio, US (AWS)", visible: true)
      }

      def aws_options(project, name)
        option_tree, parents = described_class.generate_postgres_options(project, location: [aws_location])
        OptionTreeGenerator.generate_allowed_options(name, option_tree, parents)
      end

      before { project.set_ff_enable_i8ge(true) }

      it "hides 48xlarge sizes for every family until the project enables the flag" do
        sizes = aws_options(project, "size").map { it["size"] }.uniq
        expect(sizes).to include("i8g.24xlarge", "i8ge.24xlarge")
        expect(sizes.grep(/48xlarge/)).to be_empty
      end

      it "offers 48xlarge sizes with the 192 vCPU storage size for enabled families once the project enables the flag" do
        project.set_ff_enable_aws_48xlarge(true)

        sizes = aws_options(project, "size").map { it["size"] }.uniq
        expect(sizes).to include("i8g.48xlarge", "i8ge.48xlarge")
        expect(sizes).not_to include("i7i.48xlarge", "i7ie.48xlarge")

        allowed_storage = aws_options(project, "storage_size")
        expect(allowed_storage.select { it["size"] == "i8g.48xlarge" }.map { it["storage_size"] }).to eq([45000])
        expect(allowed_storage.select { it["size"] == "i8ge.48xlarge" }.map { it["storage_size"] }).to eq([120000])
      end
    end
  end

  describe "#setup_log_aggregation" do
    let(:pg_svc_prj) { Project.create(name: "pg-svc-project") }

    before do
      allow(Config).to receive(:postgres_service_project_id).and_return(pg_svc_prj.id)
    end

    it "is a noop if parseable is not available" do
      postgres_resource.setup_log_aggregation
      expect(postgres_resource.parseable_password).to be_nil
    end

    it "sets up log aggregation if parseable is available" do
      client = instance_double(Parseable::Client)
      expect(ParseableResource).to receive(:client_for_project).and_return(client)
      expect(client).to receive_messages(create_stream: "test-stream", create_role: "test-role", create_user: "test-parseable-pass")
      expect(client).to receive(:set_retention).with(stream_name: postgres_resource.ubid, duration_days: ParseableResource::LOG_RETENTION_DAYS)
      postgres_resource.setup_log_aggregation
      expect(postgres_resource.parseable_password).to eq("test-parseable-pass")
    end
  end
end
