defmodule SofiTrader.Kalshi.Orders do
  @moduledoc """
  Kalshi Orders API client.

  Provides functions for creating, modifying, and canceling orders.

  ## Order Basics

  Kalshi prediction markets have two sides:
  - YES: Pays $1.00 if the event occurs
  - NO: Pays $1.00 if the event doesn't occur

  Prices are in cents (1-99) or dollars ("0.01" - "0.99").
  The YES price + NO price always equals ~$1.00 (minus spread).

  ## Actions vs Sides

  - `action`: "buy" or "sell" - are you buying or selling contracts?
  - `side`: "yes" or "no" - which type of contract?

  Examples:
  - Buy YES at 30¢: You pay 30¢, receive $1.00 if event happens
  - Sell YES at 70¢: You receive 70¢, owe $1.00 if event happens (short)
  - Buy NO at 30¢: You pay 30¢, receive $1.00 if event doesn't happen
  """

  alias SofiTrader.Kalshi.Client

  @doc """
  Place a new order.

  ## Required Parameters
    - `ticker` - Market ticker
    - `side` - "yes" or "no"
    - `action` - "buy" or "sell"
    - `count` - Number of contracts
    - `type` - "limit" or "market"

  ## Pricing (required for limit orders)
    - `yes_price` - Price in cents (1-99), OR
    - `no_price` - Price in cents (1-99), OR
    - `yes_price_dollars` - Price as string ("0.30"), OR
    - `no_price_dollars` - Price as string ("0.30")

  ## Optional Parameters
    - `time_in_force` - "gtc" (good til canceled), "ioc" (immediate or cancel), "fok" (fill or kill)
    - `expiration_ts` - Unix timestamp for order expiration
    - `post_only` - Boolean, maker-only execution
    - `reduce_only` - Boolean, decrease position only
    - `client_order_id` - Custom order ID for tracking

  ## Examples

      # Buy 10 YES contracts at 30¢
      Orders.create_order("KXBTC-24DEC31-T100000",
        side: "yes",
        action: "buy",
        count: 10,
        type: "limit",
        yes_price: 30
      )

      # Market order to buy 5 NO contracts
      Orders.create_order("KXBTC-24DEC31-T100000",
        side: "no",
        action: "buy",
        count: 5,
        type: "market"
      )
  """
  def create_order(ticker, opts) do
    order = %{
      ticker: ticker,
      side: Keyword.fetch!(opts, :side),
      action: Keyword.fetch!(opts, :action),
      count: Keyword.fetch!(opts, :count),
      type: Keyword.fetch!(opts, :type)
    }

    # Add optional pricing
    order = add_pricing(order, opts)

    # Add optional parameters
    order = add_optional_params(order, opts, [
      :time_in_force,
      :expiration_ts,
      :post_only,
      :reduce_only,
      :client_order_id,
      :buy_max_cost
    ])

    Client.post("/trade-api/v2/portfolio/orders", order)
  end

  @doc """
  Create multiple orders in a single request (up to 20).

  Each order in the list should be a map with the same structure as create_order.
  """
  def batch_create_orders(orders) when is_list(orders) and length(orders) <= 20 do
    Client.post("/trade-api/v2/portfolio/orders/batched", %{orders: orders})
  end

  @doc """
  Get all orders for the authenticated user.

  ## Options
    - `:ticker` - Filter by market ticker
    - `:status` - Filter by status: "resting", "canceled", "executed", "pending"
    - `:limit` - Number of results
    - `:cursor` - Pagination cursor
  """
  def list_orders(opts \\ []) do
    params = Keyword.take(opts, [:ticker, :status, :limit, :cursor])
    Client.get("/trade-api/v2/portfolio/orders", params)
  end

  @doc """
  Get a specific order by ID.
  """
  def get_order(order_id) do
    Client.get("/trade-api/v2/portfolio/orders/#{order_id}")
  end

  @doc """
  Cancel an order by ID.
  """
  def cancel_order(order_id) do
    Client.delete("/trade-api/v2/portfolio/orders/#{order_id}")
  end

  @doc """
  Cancel all resting orders, optionally filtered by market.

  ## Options
    - `:ticker` - Only cancel orders for this market
  """
  def cancel_all_orders(opts \\ []) do
    ticker = Keyword.get(opts, :ticker)
    path = if ticker do
      "/trade-api/v2/portfolio/orders?ticker=#{ticker}"
    else
      "/trade-api/v2/portfolio/orders"
    end
    Client.delete(path)
  end

  @doc """
  Amend an existing order (change price and/or count).

  ## Options
    - `:count` - New contract count
    - `:yes_price` / `:no_price` - New price in cents
    - `:yes_price_dollars` / `:no_price_dollars` - New price as string
  """
  def amend_order(order_id, opts) do
    body = %{}
    body = add_pricing(body, opts)
    body = if Keyword.has_key?(opts, :count), do: Map.put(body, :count, opts[:count]), else: body

    Client.put("/trade-api/v2/portfolio/orders/#{order_id}", body)
  end

  @doc """
  Decrease the size of an existing order.
  """
  def decrease_order(order_id, reduce_by) do
    Client.post("/trade-api/v2/portfolio/orders/#{order_id}/decrease", %{reduce_by: reduce_by})
  end

  @doc """
  Get order fills (executed trades).

  ## Options
    - `:ticker` - Filter by market
    - `:order_id` - Filter by order
    - `:limit` - Number of results
    - `:cursor` - Pagination cursor
  """
  def list_fills(opts \\ []) do
    params = Keyword.take(opts, [:ticker, :order_id, :limit, :cursor, :min_ts, :max_ts])
    Client.get("/trade-api/v2/portfolio/fills", params)
  end

  # Private helpers

  defp add_pricing(order, opts) do
    order
    |> maybe_add(opts, :yes_price)
    |> maybe_add(opts, :no_price)
    |> maybe_add(opts, :yes_price_dollars)
    |> maybe_add(opts, :no_price_dollars)
  end

  defp add_optional_params(order, opts, keys) do
    Enum.reduce(keys, order, fn key, acc ->
      maybe_add(acc, opts, key)
    end)
  end

  defp maybe_add(map, opts, key) do
    case Keyword.get(opts, key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end
end
