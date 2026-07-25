class CreateRecipes < ActiveRecord::Migration[8.1]
  def change
    create_table :recipes do |t|
      t.string  :source_url, null: false   # normalized: tracking params & fragments stripped
      t.string  :source_name
      t.string  :canonical_title
      t.boolean :make_again                # the verdict — one row per recipe, latest tap wins

      t.timestamps
    end

    # §3 — the normalized URL *is* the recipe's identity, so the database enforces
    # it rather than trusting the upsert to be its only writer.
    add_index :recipes, :source_url, unique: true
  end
end
