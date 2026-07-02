# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:resource_discount) do
      add_column :name, :text, null: true
    end
  end
end
