# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:github_installation_spill_option) do
      foreign_key :id, :github_installation, type: :uuid, null: false, primary_key: true
      column :spill_ratio, :numeric, null: false, default: 0
      column :x64_vcpus_limit, :integer, null: false
      column :arm64_vcpus_limit, :integer, null: false
      column :x64_allocated_vcpus, :integer, null: false, default: 0
      column :arm64_allocated_vcpus, :integer, null: false, default: 0

      constraint(:x64_allocated_vcpus_within_limit) { x64_allocated_vcpus <= x64_vcpus_limit }
      constraint(:arm64_allocated_vcpus_within_limit) { arm64_allocated_vcpus <= arm64_vcpus_limit }
      constraint(:x64_allocated_vcpus_non_negative) { x64_allocated_vcpus >= 0 }
      constraint(:arm64_allocated_vcpus_non_negative) { arm64_allocated_vcpus >= 0 }
      constraint(:x64_vcpus_limit_non_negative) { x64_vcpus_limit >= 0 }
      constraint(:arm64_vcpus_limit_non_negative) { arm64_vcpus_limit >= 0 }
      constraint(:spill_ratio_range) { (spill_ratio >= 0) & (spill_ratio <= 1) }
    end
  end
end
