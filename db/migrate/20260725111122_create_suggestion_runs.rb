class CreateSuggestionRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :suggestion_runs do |t|
      t.integer  :status, null: false, default: 0   # enum: queued / running / completed / failed
      t.datetime :archived_at                       # set when inventory coverage drops — §5
      t.text     :inventory_snapshot                # JSON of items at time of request
      t.text     :prompt_notes                      # optional user free-text ("something quick")
      t.text     :error_message

      t.timestamps
    end

    # The main view lists active runs and the history view lists archived ones, so
    # every listing query filters on this column (§5).
    add_index :suggestion_runs, :archived_at
  end
end
