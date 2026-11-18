# frozen_string_literal: true

class Prog::SetupCpuGovernor < Prog::Base
  subject_is :sshable

  label def start
    sshable.write_file("/etc/systemd/system/cpu-governor.service", <<UNIT)
[Unit]
Description=Use the performance cpufreq governor

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do if [ -e $$g ]; then echo performance > $$g; fi; done'

[Install]
WantedBy=multi-user.target
UNIT
    sshable.cmd("sudo systemctl daemon-reload")
    sshable.cmd("sudo systemctl enable cpu-governor.service")
    sshable.cmd("sudo systemctl restart cpu-governor.service")
    pop "cpu governor configured"
  end
end
