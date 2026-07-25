class CreatePantryItems < ActiveRecord::Migration[8.1]
  def change
    create_table :pantry_items do |t|
      t.string  :name, null: false
      t.decimal :quantity, precision: 8, scale: 2, default: 1
      t.string  :unit                 # "g", "ml", "pcs", "cans" — free text, normalized lightly
      t.integer :location, null: false, default: 0   # enum: pantry / fridge / freezer
      t.integer :category             # enum: produce / dairy / protein / grains / condiments / other
      t.date    :expires_on

      t.timestamps
    end

    add_index :pantry_items, :location
    add_index :pantry_items, :expires_on
  end
end
