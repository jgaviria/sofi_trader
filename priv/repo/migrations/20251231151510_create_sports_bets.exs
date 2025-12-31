defmodule SofiTrader.Repo.Migrations.CreateSportsBets do
  use Ecto.Migration

  def change do
    # Sports bets table - tracks each bet with AI analysis and outcomes
    create table(:sports_bets) do
      # Kalshi identifiers
      add :kalshi_fill_id, :string          # Kalshi fill ID for matching
      add :kalshi_order_id, :string         # Kalshi order ID
      add :market_ticker, :string, null: false
      add :event_ticker, :string

      # Market info at time of bet
      add :market_title, :string
      add :team_a, :string                  # First team (YES side)
      add :team_b, :string                  # Second team (NO side)
      add :sport, :string                   # :soccer, :nfl, :nba, :nhl, :mlb

      # Bet details
      add :side, :string, null: false       # "yes" or "no"
      add :action, :string, null: false     # "buy" or "sell"
      add :contracts, :integer, null: false # Number of contracts
      add :price_cents, :integer, null: false # Entry price per contract (cents)
      add :cost_cents, :integer             # Total cost (price * contracts)
      add :fees_cents, :integer, default: 0

      # AI analysis at time of bet (if available)
      add :ai_recommendation, :string       # "yes", "no", "skip" or nil if not AI-driven
      add :ai_confidence, :decimal          # 0.0 - 1.0
      add :ai_fair_value, :integer          # AI's estimated fair value (cents)
      add :ai_edge, :integer                # Expected edge (cents)
      add :ai_reasoning, :text              # AI's reasoning
      add :ai_key_factors, {:array, :string} # Key factors from AI
      add :ai_model, :string                # Model used: "gpt-4o", "o4-mini", etc.

      # Web context that was fetched (if any)
      add :web_context_summary, :text       # Summary of tournament/match context

      # Outcome tracking
      add :status, :string, default: "pending"  # "pending", "won", "lost", "push", "sold"
      add :settlement_value, :integer       # 0 or 100 (cents per contract)
      add :payout_cents, :integer           # Total payout if won
      add :profit_cents, :integer           # Net profit/loss (payout - cost)
      add :roi_percent, :decimal            # Return on investment

      # Close tracking (if sold before settlement)
      add :close_price_cents, :integer      # Price if sold before settlement
      add :close_payout_cents, :integer     # Payout from selling

      # Timestamps
      add :placed_at, :utc_datetime         # When bet was placed
      add :game_date, :date                 # When the game was played
      add :settled_at, :utc_datetime        # When bet was settled
      add :synced_at, :utc_datetime         # Last sync from Kalshi

      timestamps()
    end

    # Indexes for efficient queries
    create unique_index(:sports_bets, [:kalshi_fill_id], where: "kalshi_fill_id IS NOT NULL")
    create index(:sports_bets, [:market_ticker])
    create index(:sports_bets, [:sport])
    create index(:sports_bets, [:status])
    create index(:sports_bets, [:placed_at])
    create index(:sports_bets, [:game_date])
    create index(:sports_bets, [:ai_recommendation])
    create index(:sports_bets, [:ai_confidence])

    # Bet sync tracking - to know what we've already synced
    create table(:bet_sync_state) do
      add :last_fill_timestamp, :utc_datetime  # Last fill we synced
      add :last_settlement_check, :utc_datetime # Last time we checked settlements
      add :fills_synced_count, :integer, default: 0
      add :settlements_synced_count, :integer, default: 0

      timestamps()
    end
  end
end
