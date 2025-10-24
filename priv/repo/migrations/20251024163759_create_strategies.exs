defmodule SofiTrader.Repo.Migrations.CreateStrategies do
  use Ecto.Migration

  def change do
    # Strategies table
    create table(:strategies) do
      add :name, :string, null: false
      add :symbol, :string, null: false
      add :type, :string, null: false  # "rsi_mean_reversion", "ma_crossover", etc.

      # Strategy-specific configuration (JSON)
      # Example for RSI: %{rsi_period: 14, oversold_threshold: 30, overbought_threshold: 70, timeframe: "5min"}
      add :config, :map, default: %{}

      # Risk management parameters (JSON)
      # Example: %{position_size_pct: 10.0, stop_loss_pct: 2.0, take_profit_pct: 5.0, max_positions: 3, ...}
      add :risk_params, :map, default: %{}

      add :status, :string, default: "stopped"  # active, paused, stopped

      # Performance statistics (JSON)
      add :stats, :map, default: %{}

      timestamps()
    end

    # Strategy positions table
    create table(:strategy_positions) do
      add :strategy_id, references(:strategies, on_delete: :delete_all), null: false
      add :symbol, :string, null: false
      add :side, :string, null: false  # "buy" or "sell"
      add :quantity, :integer, null: false

      add :entry_price, :decimal, precision: 10, scale: 2
      add :current_price, :decimal, precision: 10, scale: 2
      add :stop_loss_price, :decimal, precision: 10, scale: 2
      add :take_profit_price, :decimal, precision: 10, scale: 2

      add :pnl, :decimal, precision: 10, scale: 2, default: 0.0
      add :pnl_percent, :decimal, precision: 10, scale: 2, default: 0.0

      add :status, :string, default: "open"  # open, closed
      add :close_reason, :string  # "take_profit", "stop_loss", "manual", "strategy_signal"

      add :opened_at, :utc_datetime
      add :closed_at, :utc_datetime

      timestamps()
    end

    # Strategy trades table (individual order executions)
    create table(:strategy_trades) do
      add :strategy_id, references(:strategies, on_delete: :delete_all), null: false
      add :position_id, references(:strategy_positions, on_delete: :nilify_all)
      add :order_id, :string  # Tradier order ID

      add :symbol, :string, null: false
      add :side, :string, null: false  # "buy" or "sell"
      add :quantity, :integer, null: false
      add :price, :decimal, precision: 10, scale: 2
      add :fees, :decimal, precision: 10, scale: 2, default: 0.0

      # For closing trades
      add :pnl, :decimal, precision: 10, scale: 2
      add :pnl_percent, :decimal, precision: 10, scale: 2

      add :executed_at, :utc_datetime

      timestamps()
    end

    # Create indexes for better query performance
    create index(:strategies, [:symbol])
    create index(:strategies, [:status])
    create index(:strategies, [:type])

    create index(:strategy_positions, [:strategy_id])
    create index(:strategy_positions, [:symbol])
    create index(:strategy_positions, [:status])

    create index(:strategy_trades, [:strategy_id])
    create index(:strategy_trades, [:position_id])
    create index(:strategy_trades, [:symbol])
    create index(:strategy_trades, [:executed_at])
  end
end
