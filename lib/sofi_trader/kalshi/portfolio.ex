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
