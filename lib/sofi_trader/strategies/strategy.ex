defmodule SofiTrader.Strategies.Strategy do
  @moduledoc """
  Schema for trading strategies.

  A strategy defines the rules for automated trading, including entry/exit conditions,
  risk management parameters, and performance tracking.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SofiTrader.Strategies.{Position, Trade}

  schema "strategies" do
    field :name, :string
    field :symbol, :string
    field :type, :string
    field :config, :map, default: %{}
    field :risk_params, :map, default: %{}
    field :status, :string, default: "stopped"
    field :stats, :map, default: %{}

    has_many :positions, Position
    has_many :trades, Trade

    timestamps()
  end

  @doc """
  Changeset for creating or updating a strategy.
  """
  def changeset(strategy, attrs) do
    strategy
    |> cast(attrs, [:name, :symbol, :type, :config, :risk_params, :status, :stats])
    |> validate_required([:name, :symbol, :type])
    |> validate_inclusion(:type, ["rsi_mean_reversion", "ma_crossover"])
    |> validate_inclusion(:status, ["active", "paused", "stopped"])
    |> validate_config()
    |> validate_risk_params()
  end

  defp validate_config(changeset) do
    case get_field(changeset, :type) do
      "rsi_mean_reversion" ->
        validate_rsi_config(changeset)

      "ma_crossover" ->
        validate_ma_config(changeset)

      _ ->
        changeset
    end
  end

  defp validate_rsi_config(changeset) do
    config = get_field(changeset, :config) || %{}

    with {:ok, _} <- validate_rsi_period(config),
         {:ok, _} <- validate_thresholds(config),
         {:ok, _} <- validate_timeframe(config) do
      changeset
    else
      {:error, msg} ->
        add_error(changeset, :config, msg)
    end
  end

  defp validate_ma_config(changeset) do
    config = get_field(changeset, :config) || %{}

    with {:ok, _} <- validate_ma_periods(config),
         {:ok, _} <- validate_timeframe(config) do
      changeset
    else
      {:error, msg} ->
        add_error(changeset, :config, msg)
    end
  end

  defp validate_rsi_period(%{"rsi_period" => period}) when is_integer(period) and period > 0,
    do: {:ok, period}

  defp validate_rsi_period(%{}), do: {:ok, 14}  # Default
  defp validate_rsi_period(_), do: {:error, "rsi_period must be a positive integer"}

  defp validate_thresholds(%{"oversold_threshold" => os, "overbought_threshold" => ob})
       when is_number(os) and is_number(ob) and os < ob and os > 0 and ob < 100,
       do: {:ok, {os, ob}}

  defp validate_thresholds(%{}), do: {:ok, {30, 70}}  # Defaults
  defp validate_thresholds(_), do: {:error, "invalid RSI thresholds"}

  defp validate_ma_periods(%{"fast_period" => fast, "slow_period" => slow})
       when is_integer(fast) and is_integer(slow) and fast < slow and fast > 0,
       do: {:ok, {fast, slow}}

  defp validate_ma_periods(%{}), do: {:ok, {9, 21}}  # Defaults
  defp validate_ma_periods(_), do: {:error, "invalid MA periods"}

  defp validate_timeframe(%{"timeframe" => tf})
       when tf in ["1min", "5min", "15min", "30min", "1hour", "daily"],
       do: {:ok, tf}

  defp validate_timeframe(%{}), do: {:ok, "5min"}  # Default
  defp validate_timeframe(_), do: {:error, "invalid timeframe"}

  defp validate_risk_params(changeset) do
    risk_params = get_field(changeset, :risk_params) || %{}

    with {:ok, _} <- validate_position_size(risk_params),
         {:ok, _} <- validate_stop_loss(risk_params),
         {:ok, _} <- validate_take_profit(risk_params),
         {:ok, _} <- validate_max_positions(risk_params) do
      changeset
    else
      {:error, msg} ->
        add_error(changeset, :risk_params, msg)
    end
  end

  defp validate_position_size(%{"position_size_pct" => pct})
       when is_number(pct) and pct > 0 and pct <= 100,
       do: {:ok, pct}

  defp validate_position_size(%{}), do: {:ok, 10.0}  # Default
  defp validate_position_size(_), do: {:error, "position_size_pct must be between 0 and 100"}

  defp validate_stop_loss(%{"stop_loss_pct" => pct})
       when is_number(pct) and pct > 0 and pct <= 100,
       do: {:ok, pct}

  defp validate_stop_loss(%{}), do: {:ok, 2.0}  # Default
  defp validate_stop_loss(_), do: {:error, "stop_loss_pct must be between 0 and 100"}

  defp validate_take_profit(%{"take_profit_pct" => pct})
       when is_number(pct) and pct > 0 and pct <= 1000,
       do: {:ok, pct}

  defp validate_take_profit(%{}), do: {:ok, 5.0}  # Default
  defp validate_take_profit(_), do: {:error, "take_profit_pct must be positive"}

  defp validate_max_positions(%{"max_positions" => num})
       when is_integer(num) and num > 0,
       do: {:ok, num}

  defp validate_max_positions(%{}), do: {:ok, 3}  # Default
  defp validate_max_positions(_), do: {:error, "max_positions must be a positive integer"}

  @doc """
  Returns default configuration for a strategy type.
  """
  def default_config("rsi_mean_reversion") do
    %{
      "rsi_period" => 14,
      "oversold_threshold" => 30,
      "overbought_threshold" => 70,
      "timeframe" => "5min"
    }
  end

  def default_config("ma_crossover") do
    %{
      "fast_period" => 9,
      "slow_period" => 21,
      "timeframe" => "5min"
    }
  end

  def default_config(_), do: %{}

  @doc """
  Returns default risk parameters.
  """
  def default_risk_params do
    %{
      "position_size_pct" => 10.0,
      "stop_loss_pct" => 2.0,
      "take_profit_pct" => 5.0,
      "max_positions" => 3,
      "max_positions_per_symbol" => 1,
      "max_daily_loss_pct" => 3.0,
      "cooldown_minutes" => 15
    }
  end

  @doc """
  Initialize stats map for a new strategy.
  """
  def initial_stats do
    %{
      "total_trades" => 0,
      "winning_trades" => 0,
      "losing_trades" => 0,
      "win_rate" => 0.0,
      "total_pnl" => 0.0,
      "total_pnl_pct" => 0.0,
      "largest_win" => 0.0,
      "largest_loss" => 0.0,
      "current_streak" => 0,
      "started_at" => nil,
      "last_trade_at" => nil
    }
  end
end
