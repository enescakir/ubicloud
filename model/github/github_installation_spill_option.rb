# frozen_string_literal: true

require_relative "../../model"

class GithubInstallationSpillOption < Sequel::Model
  plugin ResourceMethods, referencing: UBID::TYPE_GITHUB_INSTALLATION
  many_to_one :installation, class: :GithubInstallation, key: :id
end

# Table: github_installation_spill_option
# Columns:
#  id                    | uuid    | PRIMARY KEY
#  enabled               | boolean | NOT NULL DEFAULT true
#  spill_ratio           | numeric | NOT NULL DEFAULT 0
#  x64_vcpus_limit       | integer | NOT NULL
#  arm64_vcpus_limit     | integer | NOT NULL
#  x64_allocated_vcpus   | integer | NOT NULL DEFAULT 0
#  arm64_allocated_vcpus | integer | NOT NULL DEFAULT 0
# Indexes:
#  github_installation_spill_option_pkey | PRIMARY KEY btree (id)
# Check constraints:
#  arm64_allocated_vcpus_non_negative | (arm64_allocated_vcpus >= 0)
#  arm64_allocated_vcpus_within_limit | (arm64_allocated_vcpus <= arm64_vcpus_limit)
#  arm64_vcpus_limit_non_negative     | (arm64_vcpus_limit >= 0)
#  spill_ratio_range                  | (spill_ratio >= 0::numeric AND spill_ratio <= 1::numeric)
#  x64_allocated_vcpus_non_negative   | (x64_allocated_vcpus >= 0)
#  x64_allocated_vcpus_within_limit   | (x64_allocated_vcpus <= x64_vcpus_limit)
#  x64_vcpus_limit_non_negative       | (x64_vcpus_limit >= 0)
# Foreign key constraints:
#  github_installation_spill_option_id_fkey | (id) REFERENCES github_installation(id)
