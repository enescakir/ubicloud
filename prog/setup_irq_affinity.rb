# frozen_string_literal: true

class Prog::SetupIrqAffinity < Prog::Base
  subject_is :sshable, :vm_host

  label def start
    cpus = vm_host.cpus_dataset.where(io: true).select_order_map(:cpu_number)
    pop "host has no io cpus" if cpus.empty?

    # The kernel refuses to move some interrupts. The unit logs such a
    # write and goes on, because a failed unit would block the strand of
    # the host on every retry.
    sshable.write_file("/etc/systemd/system/nic-irq-affinity.service", <<UNIT)
[Unit]
Description=Handle NIC interrupts on the io cpus
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for irq in /sys/class/net/*/device/msi_irqs/*; do if [ -e $$irq ]; then echo #{cpus.join(",")} > /proc/irq/$${irq##*/}/smp_affinity_list; fi; done; true'

[Install]
WantedBy=multi-user.target
UNIT
    sshable.cmd("sudo systemctl daemon-reload")
    sshable.cmd("sudo systemctl enable nic-irq-affinity.service")
    sshable.cmd("sudo systemctl restart nic-irq-affinity.service")
    pop "nic irq affinity configured"
  end
end
