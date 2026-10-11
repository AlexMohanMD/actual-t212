# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_11_144454) do
  create_table "sync_states", force: :cascade do |t|
    t.datetime "last_synced_at"
    t.decimal "last_balance", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "transactions", force: :cascade do |t|
    t.string "payee"
    t.string "notes"
    t.decimal "amount", precision: 12, scale: 2
    t.boolean "synced_to_actual"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "occurred_at"
    t.string "imported_id"
    t.index ["imported_id"], name: "index_transactions_on_imported_id", unique: true
  end
end
