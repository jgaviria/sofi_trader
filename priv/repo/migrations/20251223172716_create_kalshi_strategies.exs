defmodule SofiTrader.Repo.Migrations.CreateKalshiStrategies do
  use Ecto.Migration

  def change do
    # Kalshi strategies table
    create table(:kalshi_strategies) do
      add :name, :string, null: false
      add :market_ticker, :string  # Specific market (optional - can monitor events)
      add :event_ticker, :string   # Event to monitor (optional)
      add :series_ticker, :string  # Series to monitor (optional)

      # Strategy type: "odds_monitor", "auto_bid", "arbitrage"
      add :type, :string, null: false

      # Strategy-specific configuration (JSON)
      # Example for odds_monitor:
      #   %{
      #     target_side: "yes",
      #     price_threshold: 30,  # Alert when YES price drops below 30¢
      #     volume_threshold: 1000,
      #     alert_on_threshold_cross: true
      #   }
      # Example for auto_bid:
      #   %{
      #     side: "yes",
      #     action: "buy",
      #     target_price: 25,  # Place bid at 25¢
      #     trigger_price: 30, # When market price is at 30¢
      #     max_contracts: 100,
      #     time_in_force: "gtc"
      #   }
      add :config, :map, default: %{}

      # Risk management parameters
      # Example:
      #   %{
      #     max_position_size: 1000,  # Max contracts
      #     max_daily_loss_cents: 10000,  # $100 max daily loss
      #     max_total_exposure_cents: 50000,  # $500 max exposure
      #     cooldown_seconds: 60
      #   }
      add :risk_params, :map, default: %{}

      # Alert configuration
      # %{
      #   channels: ["pubsub", "webhook"],
      #   webhook_url: "https://...",
      #   alert_cooldown_seconds: 300
      # }
      add :alert_config, :map, default: %{}

      add :status, :string, default: "stopped"  # active, paused, stopped

      # Performance and state tracking
      add :stats, :map, default: %{}
      add :last_alert_at, :utc_datetime
      add :last_trade_at, :utc_datetime

      timestamps()
    end

    # Kalshi positions table
    create table(:kalshi_positions) do
      add :strategy_id, references(:kalshi_strategies, on_delete: :delete_all)
      add :market_ticker, :string, null: false

      add :side, :string, null: false        # "yes" or "no"
      add :contracts, :integer, null: false  # Number of contracts
      add :avg_price_cents, :integer         # Average entry price in cents

      # Current market data
      add :current_price_cents, :integer
      add :current_value_cents, :integer

      # P&L
      add :realized_pnl_cents, :integer, default: 0
      add :unrealized_pnl_cents, :integer, default: 0

      add :status, :string, default: "open"  # open, closed, settled
      add :settlement_value, :integer        # Settlement payout (0 or 100 cents per contract)

      add :opened_at, :utc_datetime
      add :closed_at, :utc_datetime

      timestamps()
    end

    # Kalshi orders table (tracks all orders placed)
    create table(:kalshi_orders) do
      add :strategy_id, references(:kalshi_strategies, on_delete: :delete_all)
      add :position_id, references(:kalshi_positions, on_delete: :nilify_all)

      add :order_id, :string, null: false  # Kalshi order ID
      add :client_order_id, :string        # Our reference ID
      add :market_ticker, :string, null: false

      add :side, :string, null: false      # "yes" or "no"
      add :action, :string, null: false    # "buy" or "sell"
      add :type, :string, null: false      # "limit" or "market"

      add :count, :integer, null: false    # Contracts requested
      add :filled_count, :integer, default: 0
      add :remaining_count, :integer

      add :price_cents, :integer           # Limit price
      add :avg_fill_price_cents, :integer  # Actual fill price

      add :status, :string                 # "resting", "executed", "canceled", "pending"
      add :time_in_force, :string          # "gtc", "ioc", "fok"

      add :fees_cents, :integer, default: 0

      add :placed_at, :utc_datetime
      add :filled_at, :utc_datetime
      add :canceled_at, :utc_datetime

      timestamps()
    end

    # Kalshi alerts table (log of all alerts sent)
    create table(:kalshi_alerts) do
      add :strategy_id, references(:kalshi_strategies, on_delete: :delete_all)
      add :market_ticker, :string

      add :alert_type, :string, null: false  # "price_threshold", "volume_spike", "position_update", "order_filled"
      add :severity, :string, default: "info"  # "info", "warning", "critical"

      add :message, :text
      add :data, :map  # Alert payload

      add :channels_sent, {:array, :string}  # ["pubsub", "webhook", "ui"]
      add :acknowledged, :boolean, default: false
      add :acknowledged_at, :utc_datetime

      timestamps()
    end

    # Indexes
    create index(:kalshi_strategies, [:market_ticker])
    create index(:kalshi_strategies, [:event_ticker])
    create index(:kalshi_strategies, [:type])
    create index(:kalshi_strategies, [:status])

    create index(:kalshi_positions, [:strategy_id])
    create index(:kalshi_positions, [:market_ticker])
    create index(:kalshi_positions, [:status])

    create index(:kalshi_orders, [:strategy_id])
    create index(:kalshi_orders, [:position_id])
    create index(:kalshi_orders, [:order_id])
    create index(:kalshi_orders, [:market_ticker])
    create index(:kalshi_orders, [:status])

    create index(:kalshi_alerts, [:strategy_id])
    create index(:kalshi_alerts, [:market_ticker])
    create index(:kalshi_alerts, [:alert_type])
    create index(:kalshi_alerts, [:inserted_at])
  end
end
