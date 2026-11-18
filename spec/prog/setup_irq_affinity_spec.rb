# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupIrqAffinity do
  subject(:sia) {
    described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}], prog: "SetupIrqAffinity"))
  }

  let(:vmh) { Prog::Vm::HostNexus.assemble("1.1.1.1").subject }

  describe "#start" do
    it "installs a unit that moves the NIC interrupts to the io cpus, runs it, and pops" do
      VmHostCpu.import([:vm_host_id, :cpu_number, :io], [[vmh.id, 16, true], [vmh.id, 0, true], [vmh.id, 1, false]])

      expect(sia.sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/nic-irq-affinity.service > /dev/null", stdin: <<UNIT)
[Unit]
Description=Handle NIC interrupts on the io cpus
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for irq in /sys/class/net/*/device/msi_irqs/*; do if [ -e $$irq ]; then echo 0,16 > /proc/irq/$${irq##*/}/smp_affinity_list; fi; done; true'

[Install]
WantedBy=multi-user.target
UNIT
      expect(sia.sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sia.sshable).to receive(:_cmd).with("sudo systemctl enable nic-irq-affinity.service")
      expect(sia.sshable).to receive(:_cmd).with("sudo systemctl restart nic-irq-affinity.service")
      expect { sia.start }.to exit({"msg" => "nic irq affinity configured"})
    end

    it "pops without a unit when the host has no io cpus" do
      VmHostCpu.import([:vm_host_id, :cpu_number, :io], [[vmh.id, 0, false]])
      expect(sia.sshable).not_to receive(:_cmd)

      expect { sia.start }.to exit({"msg" => "host has no io cpus"})
    end
  end
end
