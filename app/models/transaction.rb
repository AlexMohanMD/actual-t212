class Transaction < ApplicationRecord
  scope :unsynced, -> { where(synced_to_actual: [ false, nil ]) }
  scope :synced, -> { where(synced_to_actual: true) }

  validates :imported_id, uniqueness: true, allow_nil: true
end
