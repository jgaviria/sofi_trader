defmodule SofiTrader.Kalshi.Portfolio do
  @moduledoc """
  Kalshi Portfolio API client.

  Provides functions for checking account balance, positions, and settlements.
  """

  alias SofiTrader.Kalshi.Client

  @doc """
  Get account balance information.

  Returns:
  - `balance` - Available cash balance in cents
  - `payout` - Pending payouts
  """
  def get_balance do
    Client.get("/trade-api/v2/portfolio/balance")
  end

  @doc """
  Get all positions for the authenticated user.

  ## Options
    - `:ticker` - Filter by market ticker
    - `:event_ticker` - Filter by event
    - `:settlement_status` - Filter: "unsettled", "settled"
    - `:limit` - Number of results
    - `:cursor` - Pagination cursor
  """
  def list_positions(opts \\ []) do
    params = Keyword.take(opts, [:ticker, :event_ticker, :settlement_status, :limit, :cursor])
    Client.get("/trade-api/v2/portfolio/positions", params)
  end

  @doc """
  Get position for a specific market.
  """
  def get_position(ticker) do
    Client.get("/trade-api/v2/portfolio/positions/#{ticker}")
  end

  @doc """
  Get settlement history.

  ## Options
    - `:limit` - Number of results
    - `:cursor` - Pagination cursor
  """
  def list_settlements(opts \\ []) do
    params = Keyword.take(opts, [:limit, :cursor])
    Client.get("/trade-api/v2/portfolio/settlements", params)
  end

  @doc """
  Get the total value of all resting orders (funds committed to open orders).
  """
  def get_resting_order_value do
    Client.get("/trade-api/v2/portfolio/resting_order_value")
  end

  @doc """
  Get portfolio summary with positions and P&L.

  This is a convenience function that combines balance and positions.
  """
  def get_summary do
    with {:ok, balance} <- get_balance(),
         {:ok, positions} <- list_positions(settlement_status: "unsettled") do
      {:ok, %{
        balance: balance,
        positions: positions,
        summary: calculate_summary(balance, positions)
      }}
    end
  end

  @doc """
  Get complete account stats from Kalshi.

  Returns the official Kalshi numbers including:
  - Cash balance
  - Portfolio value (current positions)
  - Total account value
  - Bonus balance (if any)
  """
  def get_account_stats do
    case get_balance() do
      {:ok, balance} ->
        # Kalshi balance API returns:
        # - balance: cash available
        # - portfolio_value: value of open positions
        # - bonus_balance: promotional balance (if any)
        # - payout: pending payouts

        cash = balance["balance"] || 0
        portfolio = balance["portfolio_value"] || 0
        bonus = balance["bonus_balance"] || 0
        payout = balance["payout"] || 0

        {:ok, %{
          cash_balance_cents: cash,
          portfolio_value_cents: portfolio,
          bonus_balance_cents: bonus,
          pending_payout_cents: payout,
          total_value_cents: cash + portfolio + bonus,
          # These are from Kalshi's API directly
          raw: balance
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calculate total realized P&L from settlement history.

  This fetches ALL settlements and sums up the realized profit/loss.
  More accurate than calculating from individual fills.
  """
  def get_total_realized_pnl do
    case fetch_all_settlements() do
      {:ok, settlements} ->
        # Each settlement has: revenue (payout), yes_count/no_count, etc.
        total_revenue = settlements
        |> Enum.reduce(0, fn s, acc ->
          revenue = s["revenue"] || 0
          acc + revenue
        end)

        # Also calculate by counting settlements
        settlement_count = length(settlements)

        {:ok, %{
          total_revenue_cents: total_revenue,
          settlement_count: settlement_count,
          settlements: settlements
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fetch all settlements with pagination
  defp fetch_all_settlements do
    fetch_all_settlements(nil, [])
  end

  defp fetch_all_settlements(cursor, acc) do
    opts = [limit: 100]
    opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

    case list_settlements(opts) do
      {:ok, %{"settlements" => settlements, "cursor" => next_cursor}}
          when is_list(settlements) and length(settlements) > 0 and next_cursor != "" ->
        fetch_all_settlements(next_cursor, acc ++ settlements)

      {:ok, %{"settlements" => settlements}} when is_list(settlements) ->
        {:ok, acc ++ settlements}

      {:ok, _} ->
        {:ok, acc}

      {:error, reason} ->
        if length(acc) > 0, do: {:ok, acc}, else: {:error, reason}
    end
  end

  defp calculate_summary(balance, %{"market_positions" => positions}) do
    total_position_value = positions
    |> Enum.reduce(0, fn pos, acc ->
      # Position value based on current market price would need market data
      # For now, just count contracts
      yes_count = pos["position"] || 0
      no_count = pos["total_traded"] || 0
      acc + abs(yes_count) + abs(no_count)
    end)

    %{
      cash_balance: balance["balance"],
      total_contracts: total_position_value,
      position_count: length(positions)
    }
  end

  defp calculate_summary(balance, _) do
    %{
      cash_balance: balance["balance"],
      total_contracts: 0,
      position_count: 0
    }
  end
end
