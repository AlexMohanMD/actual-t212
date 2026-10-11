class Transaction < ApplicationRecord
  scope :unsynced, -> { where(synced_to_actual: [ false, nil ]) }
  scope :synced, -> { where(synced_to_actual: true) }
end
