defmodule SofiTrader.Kalshi.Strategy do
  @moduledoc """
  Schema for Kalshi prediction market strategies.

  ## Strategy Types

  - `:odds_monitor` - Watch markets for price/volume thresholds and send alerts
  - `:auto_bid` - Automatically place orders when conditions are met
  - `:arbitrage` - Monitor related markets for pricing inefficiencies

  ## Configuration Examples

  ### Odds Monitor
  ```elixir
  %{
    "target_side" => "yes",
    "price_below" => 30,           # Alert when YES price drops below 30¢
    "price_above" => nil,          # Or when price rises above X¢
    "volume_threshold" => 1000,    # Alert on volume spike
    "alert_on_change_pct" => 10.0  # Alert on 10% price change
  }
  ```

  ### Auto Bid
  ```elixir
  %{
    "side" => "yes",
    "action" => "buy",
    "target_price" => 25,      # Place bid at 25¢
    "trigger_price" => 30,     # When market YES price is at 30¢
    "max_contracts" => 100,
    "time_in_force" => "gtc",
    "enabled" => true
  }
  ```
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SofiTrader.Kalshi.{Position, Order, Alert}

  @type t :: %__MODULE__{}

  @strategy_types ["odds_monitor", "auto_bid", "arbitrage"]
  @statuses ["active", "paused", "stopped"]

  schema "kalshi_strategies" do
    field :name, :string
    field :market_ticker, :string
    field :event_ticker, :string
    field :series_ticker, :string
    field :type, :string
    field :config, :map, default: %{}
    field :risk_params, :map, default: %{}
    field :alert_config, :map, default: %{}
    field :status, :string, default: "stopped"
    field :stats, :map, default: %{}
    field :last_alert_at, :utc_datetime
    field :last_trade_at, :utc_datetime

    has_many :positions, Position
    has_many :orders, Order
    has_many :alerts, Alert

    timestamps()
  end

  @doc """
  Changeset for creating or updating a Kalshi strategy.
  """
  def changeset(strategy, attrs) do
    strategy
    |> cast(attrs, [
      :name, :market_ticker, :event_ticker, :series_ticker, :type,
      :config, :risk_params, :alert_config, :status, :stats,
      :last_alert_at, :last_trade_at
    ])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @strategy_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_has_target()
    |> validate_config()
    |> validate_risk_params()
    |> validate_alert_config()
  end

  defp validate_has_target(changeset) do
    market = get_field(changeset, :market_ticker)
    event = get_field(changeset, :event_ticker)
    series = get_field(changeset, :series_ticker)

    if is_nil(market) and is_nil(event) and is_nil(series) do
      add_error(changeset, :market_ticker, "must specify market_ticker, event_ticker, or series_ticker")
    else
      changeset
    end
  end

  defp validate_config(changeset) do
    case get_field(changeset, :type) do
      "odds_monitor" -> validate_odds_monitor_config(changeset)
      "auto_bid" -> validate_auto_bid_config(changeset)
      "arbitrage" -> validate_arbitrage_config(changeset)
      _ -> changeset
    end
  end

  defp validate_odds_monitor_config(changeset) do
    config = get_field(changeset, :config) || %{}

    # At least one trigger condition required
    has_price_below = is_integer(config["price_below"])
    has_price_above = is_integer(config["price_above"])
    has_volume = is_integer(config["volume_threshold"])
    has_change = is_number(config["alert_on_change_pct"])

    if has_price_below or has_price_above or has_volume or has_change do
      changeset
    else
      add_error(changeset, :config, "must specify at least one trigger condition")
    end
  end

  defp validate_auto_bid_config(changeset) do
    config = get_field(changeset, :config) || %{}

    with :ok <- validate_side(config["side"]),
         :ok <- validate_action(config["action"]),
         :ok <- validate_price(config["target_price"]),
         :ok <- validate_contracts(config["max_contracts"]) do
      changeset
    else
      {:error, msg} -> add_error(changeset, :config, msg)
    end
  end

  defp validate_arbitrage_config(changeset) do
    config = get_field(changeset, :config) || %{}

    if is_list(config["market_pairs"]) and length(config["market_pairs"]) > 0 do
      changeset
    else
      add_error(changeset, :config, "arbitrage strategy requires market_pairs")
    end
  end

  defp validate_side(side) when side in ["yes", "no"], do: :ok
  defp validate_side(_), do: {:error, "side must be 'yes' or 'no'"}

  defp validate_action(action) when action in ["buy", "sell"], do: :ok
  defp validate_action(_), do: {:error, "action must be 'buy' or 'sell'"}

  defp validate_price(price) when is_integer(price) and price >= 1 and price <= 99, do: :ok
  defp validate_price(_), do: {:error, "target_price must be between 1 and 99 cents"}

  defp validate_contracts(contracts) when is_integer(contracts) and contracts > 0, do: :ok
  defp validate_contracts(_), do: {:error, "max_contracts must be a positive integer"}

  defp validate_risk_params(changeset) do
    # Risk params are optional but validated if present
    risk = get_field(changeset, :risk_params) || %{}

    cond do
      risk["max_position_size"] && !is_integer(risk["max_position_size"]) ->
        add_error(changeset, :risk_params, "max_position_size must be an integer")

      risk["max_daily_loss_cents"] && !is_integer(risk["max_daily_loss_cents"]) ->
        add_error(changeset, :risk_params, "max_daily_loss_cents must be an integer")

      true ->
        changeset
    end
  end

  defp validate_alert_config(changeset) do
    alert_config = get_field(changeset, :alert_config) || %{}

    valid_channels = ["pubsub", "webhook", "ui"]
    channels = alert_config["channels"] || []

    if Enum.all?(channels, &(&1 in valid_channels)) do
      changeset
    else
      add_error(changeset, :alert_config, "invalid channel specified")
    end
  end

  @doc """
  Returns default configuration for a strategy type.
  """
  def default_config("odds_monitor") do
    %{
      "target_side" => "yes",
      "price_below" => nil,
      "price_above" => nil,
      "volume_threshold" => nil,
      "alert_on_change_pct" => 10.0
    }
  end

  def default_config("auto_bid") do
    %{
      "side" => "yes",
      "action" => "buy",
      "target_price" => 25,
      "trigger_price" => 30,
      "max_contracts" => 10,
      "time_in_force" => "gtc",
      "enabled" => false
    }
  end

  def default_config("arbitrage") do
    %{
      "market_pairs" => [],
      "min_spread_cents" => 5,
      "enabled" => false
    }
  end

  def default_config(_), do: %{}

  @doc """
  Returns default risk parameters.
  """
  def default_risk_params do
    %{
      "max_position_size" => 100,
      "max_daily_loss_cents" => 5000,
      "max_total_exposure_cents" => 25000,
      "cooldown_seconds" => 60
    }
  end

  @doc """
  Returns default alert configuration.
  """
  def default_alert_config do
    %{
      "channels" => ["pubsub", "ui"],
      "webhook_url" => nil,
      "alert_cooldown_seconds" => 300
    }
  end

  @doc """
  Initialize stats for a new strategy.
  """
  def initial_stats do
    %{
      "total_alerts" => 0,
      "total_orders" => 0,
      "filled_orders" => 0,
      "total_contracts_traded" => 0,
      "realized_pnl_cents" => 0,
      "started_at" => nil
    }
  end
end
