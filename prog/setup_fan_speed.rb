# frozen_string_literal: true

class Prog::SetupFanSpeed < Prog::Base
  subject_is :sshable

  label def start
    # A host without such a fan controller has nothing to set. A write
    # that fails is logged and skipped, because a failed unit would block
    # the strand of the host on every retry.
    sshable.write_file("/etc/systemd/system/fan-full-speed.service", <<UNIT)
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
    sshable.cmd("sudo systemctl daemon-reload")
    sshable.cmd("sudo systemctl enable fan-full-speed.service")
    sshable.cmd("sudo systemctl restart fan-full-speed.service")
    pop "fan speed configured"
  end
end
