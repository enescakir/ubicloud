# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::SetupFanSpeed do
  subject(:sfs) {
    described_class.new(Strand.create_with_id(sshable, prog: "SetupFanSpeed", label: "start"))
  }

  let(:sshable) { Sshable.create }

  describe "#start" do
    it "installs a unit that turns off the fan control of every NCT67xx controller, runs it, and pops" do
      expect(sfs.sshable).to receive(:_cmd).with("sudo tee /etc/systemd/system/fan-full-speed.service > /dev/null", stdin: <<UNIT)
[Unit]
Description=Run the fans of a Nuvoton NCT67xx controller at full speed

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/modprobe nct6775
ExecStart=/bin/sh -c 'for hwmon in /sys/class/hwmon/hwmon*; do case "$$(cat $$hwmon/name 2>/dev/null)" in nct67*) for pwm in $$hwmon/pwm[0-9]_enable; do if [ -e $$pwm ]; then echo 0 > $$pwm; fi; done;; esac; done; true'

[Install]
WantedBy=multi-user.target
UNIT
      expect(sfs.sshable).to receive(:_cmd).with("sudo systemctl daemon-reload")
      expect(sfs.sshable).to receive(:_cmd).with("sudo systemctl enable fan-full-speed.service")
      expect(sfs.sshable).to receive(:_cmd).with("sudo systemctl restart fan-full-speed.service")
      expect { sfs.start }.to exit({"msg" => "fan speed configured"})
    end
  end
end
