# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupCpuGovernor do
  subject(:scg) {
    described_class.new(Strand.create_with_id(sshable, prog: "SetupCpuGovernor", label: "start"))
  }

  let(:sshable) { Sshable.create }

  describe "#start" do
    it "installs a unit that sets the performance governor on every cpufreq policy, runs it, and pops" do
      expect(scg.sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/cpu-governor.service > /dev/null", stdin: <<UNIT)
[Unit]
Description=Use the performance cpufreq governor

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do if [ -e $$g ]; then echo performance > $$g; fi; done'

[Install]
WantedBy=multi-user.target
UNIT
      expect(scg.sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(scg.sshable).to receive(:_cmd).with("sudo systemctl enable cpu-governor.service")
      expect(scg.sshable).to receive(:_cmd).with("sudo systemctl restart cpu-governor.service")
      expect { scg.start }.to exit({"msg" => "cpu governor configured"})
    end
  end
end
