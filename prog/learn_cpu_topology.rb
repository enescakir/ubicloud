# frozen_string_literal: true

class Prog::LearnCpuTopology < Prog::Base
  subject_is :sshable, :vm_host

  def self.assemble(vm_host_id)
    fail "No existing VmHost" unless VmHost[vm_host_id]

    Strand.create(prog: "LearnCpuTopology", label: "start", stack: [{"subject_id" => vm_host_id}])
  end

  label def start
    if retval
      cpu_numa_nodes = retval.fetch("cpu_numa_nodes")
      cpu_cores = retval.fetch("cpu_cores")
      cpu_cppc_highest_perfs = retval.fetch("cpu_cppc_highest_perfs")
      cpus = vm_host.cpus_dataset
      cpu_count = cpus.count
      fail "VmHost has no vm_host_cpu rows to update" if cpu_count.zero?
      fail "lscpu reported #{cpu_cores.size} cpus, but VmHost has #{cpu_count} vm_host_cpu rows" if cpu_cores.size != cpu_count

      numa_node_by_cpu_number = cpu_numa_nodes.each_with_index.to_h { |numa_node, cpu_number| [cpu_number, numa_node] }
      core_number_by_cpu_number = cpu_cores.each_with_index.to_h { |core_number, cpu_number| [cpu_number, core_number] }
      cppc_highest_perf_by_cpu_number = cpu_cppc_highest_perfs.each_with_index.to_h { |cppc_highest_perf, cpu_number| [cpu_number, cppc_highest_perf] }
      cpus.update(
        # Without numa or CPPC data every branch is NULL, which PostgreSQL
        # types as text.
        numa_node: Sequel.case(numa_node_by_cpu_number, nil, :cpu_number).cast(:integer),
        core_number: Sequel.case(core_number_by_cpu_number, nil, :cpu_number),
        cppc_highest_perf: Sequel.case(cppc_highest_perf_by_cpu_number, nil, :cpu_number).cast(:integer),
      )

      pop("updated numa_node, core_number and cppc_highest_perf for #{cpu_count} cpus")
    end

    push Prog::LearnCpu
  end
end
