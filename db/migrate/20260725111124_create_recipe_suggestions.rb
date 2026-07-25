class CreateRecipeSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :recipe_suggestions do |t|
      t.references :suggestion_run, null: false, foreign_key: true
      t.references :recipe, null: false, foreign_key: true
      t.string   :title, null: false        # as presented in this run
      t.text     :summary

      # JSON-in-text (§3). Left nullable on purpose: the model declares these
      # `serialize ..., type: Array`, and that type reads NULL back as `[]` and
      # writes `[]` back out as NULL. So an empty list is a NULL here, readers never
      # see nil, and a NOT NULL constraint would only ever reject the empty case.
      t.text     :uses_items      # item names it consumes
      t.text     :missing_items   # things you'd need to buy
      t.text     :substitutions   # [{missing:, use_instead:}]

      t.datetime :cooked_at                 # set by the "I made this" flow — §4.3
      t.integer  :position

      t.timestamps
    end
  end
end
