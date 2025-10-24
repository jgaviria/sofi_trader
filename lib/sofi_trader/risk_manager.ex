defmodule SofiTrader.RiskManager do
  @moduledoc """
  Risk management module for trading strategies.

  Provides functions to calculate position sizes, validate risk parameters,
  check position limits, and enforce risk controls to protect capital.
  """

  import Ecto.Query
  alias SofiTrader.Repo
  alias SofiTrader.Strategies.{Position, Trade}
  alias SofiTrader.Tradier.Accounts

  @doc """
  Checks if a new position can be opened based on risk parameters.

  ## Parameters

    - strategy: Strategy schema
    - symbol: Stock symbol
    - current_price: Current price of the symbol

  ## Returns

    - {:ok, details} if position can be opened
    - {:error, reason} if position cannot be opened
  """
  def can_open_position?(strategy, symbol, current_price) do
    with :ok <- check_strategy_active(strategy),
         :ok <- check_max_positions(strategy),
         :ok <- check_max_positions_per_symbol(strategy, symbol),
         :ok <- check_daily_loss_limit(strategy),
         :ok <- check_cooldown_period(strategy, symbol),
         {:ok, buying_power} <- get_available_buying_power(),
         {:ok, position_size} <- calculate_position_size(strategy, current_price, buying_power) do
      {:ok,
       %{
         can_trade: true,
         position_size: position_size,
         buying_power: buying_power
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Calculates the position size based on risk parameters and available capital.

  ## Parameters

    - strategy: Strategy schema
    - current_price: Current price of the symbol
    - buying_power: Available buying power (optional, will fetch if not provided)

  ## Returns

    - {:ok, quantity} or {:error, reason}
  """
  def calculate_position_size(strategy, current_price, buying_power \\ nil) do
    risk_params = strategy.risk_params || %{}
    position_size_pct = Map.get(risk_params, "position_size_pct", 10.0)

    with {:ok, bp} <- get_or_use_buying_power(buying_power) do
      # Calculate dollar amount to invest
      position_value = bp * (position_size_pct / 100)

      # Calculate number of shares
      quantity = floor(position_value / current_price)

      if quantity > 0 do
        {:ok, quantity}
      else
        {:error, :insufficient_capital}
      end
    end
  end

  @doc """
  Calculates stop loss and take profit prices for a position.

  ## Parameters

    - strategy: Strategy schema
    - entry_price: Entry price of the position
    - side: "buy" or "sell"

  ## Returns

    - {:ok, %{stop_loss: price, take_profit: price}}
  """
  def calculate_exit_prices(strategy, entry_price, side) do
    risk_params = strategy.risk_params || %{}
    stop_loss_pct = Map.get(risk_params, "stop_loss_pct", 2.0) / 100
    take_profit_pct = Map.get(risk_params, "take_profit_pct", 5.0) / 100

    {stop_loss, take_profit} =
      case side do
        "buy" ->
          sl = Float.round(entry_price * (1 - stop_loss_pct), 2)
          tp = Float.round(entry_price * (1 + take_profit_pct), 2)
          {sl, tp}

        "sell" ->
          sl = Float.round(entry_price * (1 + stop_loss_pct), 2)
          tp = Float.round(entry_price * (1 - take_profit_pct), 2)
          {sl, tp}
      end

    {:ok, %{stop_loss: stop_loss, take_profit: take_profit}}
  end

  @doc """
  Checks if a position should be closed based on stop loss or take profit.

  ## Parameters

    - position: Position schema
    - current_price: Current market price

  ## Returns

    - {:close, reason} if position should be closed
    - :hold if position should remain open
  """
  def check_exit_conditions(position, current_price) do
    # Update position with current price
    updated_position = %{position | current_price: current_price}

    cond do
      Position.stop_loss_hit?(updated_position) ->
        {:close, "stop_loss"}

      Position.take_profit_hit?(updated_position) ->
        {:close, "take_profit"}

      true ->
        :hold
    end
  end

  @doc """
  Calculates the total P&L for today's trades.

  ## Parameters

    - strategy: Strategy schema

  ## Returns

    - {:ok, pnl_amount} or {:error, reason}
  """
  def calculate_daily_pnl(strategy) do
    today = DateTime.utc_now() |> DateTime.to_date()

    pnl =
      from(t in Trade,
        where: t.strategy_id == ^strategy.id,
        where: fragment("DATE(?)", t.executed_at) == ^today,
        select: sum(t.pnl)
      )
      |> Repo.one()
      |> case do
        nil -> Decimal.new(0)
        val -> val
      end

    {:ok, pnl}
  end

  # Private functions

  defp check_strategy_active(strategy) do
    if strategy.status == "active" do
      :ok
    else
      {:error, :strategy_not_active}
    end
  end

  defp check_max_positions(strategy) do
    risk_params = strategy.risk_params || %{}
    max_positions = Map.get(risk_params, "max_positions", 3)

    open_positions_count =
      from(p in Position,
        where: p.strategy_id == ^strategy.id and p.status == "open",
        select: count(p.id)
      )
      |> Repo.one()

    if open_positions_count < max_positions do
      :ok
    else
      {:error, :max_positions_reached}
    end
  end

  defp check_max_positions_per_symbol(strategy, symbol) do
    risk_params = strategy.risk_params || %{}
    max_per_symbol = Map.get(risk_params, "max_positions_per_symbol", 1)

    symbol_positions_count =
      from(p in Position,
        where: p.strategy_id == ^strategy.id and p.symbol == ^symbol and p.status == "open",
        select: count(p.id)
      )
      |> Repo.one()

    if symbol_positions_count < max_per_symbol do
      :ok
    else
      {:error, :max_positions_per_symbol_reached}
    end
  end

  defp check_daily_loss_limit(strategy) do
    {:ok, daily_pnl} = calculate_daily_pnl(strategy)

    risk_params = strategy.risk_params || %{}
    max_daily_loss_pct = Map.get(risk_params, "max_daily_loss_pct", 3.0)

    # Get account value to calculate loss percentage
    case get_account_value() do
      {:ok, account_value} ->
        max_loss_amount = account_value * (max_daily_loss_pct / 100)
        daily_pnl_float = Decimal.to_float(daily_pnl)

        if daily_pnl_float >= -max_loss_amount do
          :ok
        else
          {:error, :daily_loss_limit_exceeded}
        end

      {:error, _} ->
        # If we can't get account value, allow the trade but log warning
        require Logger
        Logger.warning("Could not fetch account value for daily loss check")
        :ok
    end
  end

  defp check_cooldown_period(strategy, symbol) do
    risk_params = strategy.risk_params || %{}
    cooldown_minutes = Map.get(risk_params, "cooldown_minutes", 15)

    last_trade =
      from(t in Trade,
        where: t.strategy_id == ^strategy.id and t.symbol == ^symbol,
        order_by: [desc: t.executed_at],
        limit: 1
      )
      |> Repo.one()

    case last_trade do
      nil ->
        :ok

      trade ->
        cooldown_expires = DateTime.add(trade.executed_at, cooldown_minutes * 60, :second)
        now = DateTime.utc_now()

        if DateTime.compare(now, cooldown_expires) == :gt do
          :ok
        else
          {:error, :cooldown_period_active}
        end
    end
  end

  defp get_or_use_buying_power(nil), do: get_available_buying_power()
  defp get_or_use_buying_power(bp), do: {:ok, bp}

  defp get_available_buying_power do
    account_id = get_account_id()
    token = get_token()

    case Accounts.get_balances(account_id, token: token) do
      {:ok, %{"balances" => balances}} ->
        buying_power =
          get_in(balances, ["option_buying_power"]) ||
            get_in(balances, ["stock_buying_power"]) ||
            0.0

        {:ok, buying_power}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_account_value do
    account_id = get_account_id()
    token = get_token()

    case Accounts.get_balances(account_id, token: token) do
      {:ok, %{"balances" => balances}} ->
        total_equity = get_in(balances, ["total_equity"]) || 0.0
        {:ok, total_equity}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_account_id do
    System.get_env("TRADIER_ACCOUNT_ID") || "VA35810079"
  end

  defp get_token do
    System.get_env("TRADIER_ACCESS_TOKEN")
  end

  @doc """
  Validates that a strategy's risk parameters are within acceptable ranges.

  ## Parameters

    - risk_params: Map of risk parameters

  ## Returns

    - :ok if valid
    - {:error, reasons} if invalid
  """
  def validate_risk_params(risk_params) do
    errors = []

    errors =
      case Map.get(risk_params, "position_size_pct") do
        nil -> errors
        pct when pct > 0 and pct <= 50 -> errors
        _ -> ["position_size_pct must be between 0 and 50" | errors]
      end

    errors =
      case Map.get(risk_params, "stop_loss_pct") do
        nil -> errors
        pct when pct > 0 and pct <= 20 -> errors
        _ -> ["stop_loss_pct must be between 0 and 20" | errors]
      end

    errors =
      case Map.get(risk_params, "max_positions") do
        nil -> errors
        num when num > 0 and num <= 10 -> errors
        _ -> ["max_positions must be between 1 and 10" | errors]
      end

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end
end
