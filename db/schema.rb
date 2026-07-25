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

ActiveRecord::Schema[8.1].define(version: 2026_07_25_111124) do
  create_table "pantry_items", force: :cascade do |t|
    t.integer "category"
    t.datetime "created_at", null: false
    t.date "expires_on"
    t.integer "location", default: 0, null: false
    t.string "name", null: false
    t.decimal "quantity", precision: 8, scale: 2, default: "1.0"
    t.string "unit"
    t.datetime "updated_at", null: false
    t.index ["expires_on"], name: "index_pantry_items_on_expires_on"
    t.index ["location"], name: "index_pantry_items_on_location"
  end

  create_table "recipe_suggestions", force: :cascade do |t|
    t.datetime "cooked_at"
    t.datetime "created_at", null: false
    t.text "missing_items"
    t.integer "position"
    t.integer "recipe_id", null: false
    t.text "substitutions"
    t.integer "suggestion_run_id", null: false
    t.text "summary"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.text "uses_items"
    t.index ["recipe_id"], name: "index_recipe_suggestions_on_recipe_id"
    t.index ["suggestion_run_id"], name: "index_recipe_suggestions_on_suggestion_run_id"
  end

  create_table "recipes", force: :cascade do |t|
    t.string "canonical_title"
    t.datetime "created_at", null: false
    t.boolean "make_again"
    t.string "source_name"
    t.string "source_url", null: false
    t.datetime "updated_at", null: false
    t.index ["source_url"], name: "index_recipes_on_source_url", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "suggestion_runs", force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.text "inventory_snapshot"
    t.text "prompt_notes"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["archived_at"], name: "index_suggestion_runs_on_archived_at"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "recipe_suggestions", "recipes"
  add_foreign_key "recipe_suggestions", "suggestion_runs"
  add_foreign_key "sessions", "users"
end
