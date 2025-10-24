defmodule SofiTrader.Tradier.Trading do
  @moduledoc """
  Trading operations for Tradier API.

  Provides functions to place, modify, and cancel orders.
  """

  alias SofiTrader.Tradier.Client

  @doc """
  Place an equity order.

  ## Options
    - `:class` - Order class (equity, option, multileg, combo)
    - `:symbol` - Symbol to trade
    - `:side` - buy, buy_to_cover, sell, sell_short
    - `:quantity` - Number of shares
    - `:type` - market, limit, stop, stop_limit
    - `:duration` - day, gtc, pre, post
    - `:price` - Limit price (for limit orders)
    - `:stop` - Stop price (for stop orders)
    - `:tag` - Optional order tag

  ## Examples

      iex> Trading.place_order(account_id, %{
        class: "equity",
        symbol: "AAPL",
        side: "buy",
        quantity: 100,
        type: "market",
        duration: "day"
      })
      {:ok, %{"order" => %{"id" => 123456}}}
  """
  def place_order(account_id, order_params, opts \\ []) do
    body = build_order_params(order_params)
    Client.post("/accounts/#{account_id}/orders", body, opts)
  end

  @doc """
  Modify an existing order.
  """
  def modify_order(account_id, order_id, order_params, opts \\ []) do
    body = build_order_params(order_params)
    Client.put("/accounts/#{account_id}/orders/#{order_id}", body, opts)
  end

  @doc """
  Cancel an order.
  """
  def cancel_order(account_id, order_id, opts \\ []) do
    Client.delete("/accounts/#{account_id}/orders/#{order_id}", opts)
  end

  @doc """
  Place an option order.

  ## Options
    - `:class` - option
    - `:symbol` - Underlying symbol
    - `:option_symbol` - Option symbol
    - `:side` - buy_to_open, buy_to_close, sell_to_open, sell_to_close
    - `:quantity` - Number of contracts
    - `:type` - market, limit, stop, stop_limit
    - `:duration` - day, gtc, pre, post
    - `:price` - Limit price (for limit orders)
    - `:stop` - Stop price (for stop orders)
  """
  def place_option_order(account_id, order_params, opts \\ []) do
    body = Map.put(order_params, :class, "option") |> build_order_params()
    Client.post("/accounts/#{account_id}/orders", body, opts)
  end

  @doc """
  Place a multileg option order.

  ## Options
    - `:class` - multileg
    - `:symbol` - Underlying symbol
    - `:type` - market, limit, debit, credit
    - `:duration` - day, gtc
    - `:price` - Limit price
    - `:legs` - List of legs with option_symbol, side, quantity
  """
  def place_multileg_order(account_id, order_params, opts \\ []) do
    body = build_multileg_params(order_params)
    Client.post("/accounts/#{account_id}/orders", body, opts)
  end

  @doc """
  Place a combo order (equity + option).
  """
  def place_combo_order(account_id, order_params, opts \\ []) do
    body = build_combo_params(order_params)
    Client.post("/accounts/#{account_id}/orders", body, opts)
  end

  @doc """
  Preview an order without placing it.
  """
  def preview_order(account_id, order_params, opts \\ []) do
    body = build_order_params(order_params)
    Client.post("/accounts/#{account_id}/orders/preview", body, opts)
  end

  defp build_order_params(params) do
    params
    |> Map.take([
      :class, :symbol, :side, :quantity, :type, :duration,
      :price, :stop, :tag, :option_symbol
    ])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_multileg_params(params) do
    base_params = Map.take(params, [:class, :symbol, :type, :duration, :price])
    legs = params[:legs] || []

    legs_params =
      legs
      |> Enum.with_index()
      |> Enum.flat_map(fn {leg, index} ->
        [
          {"option_symbol[#{index}]", leg[:option_symbol]},
          {"side[#{index}]", leg[:side]},
          {"quantity[#{index}]", leg[:quantity]}
        ]
      end)
      |> Map.new()

    Map.merge(base_params, legs_params)
  end

  defp build_combo_params(params) do
    # Combo orders include both equity and option legs
    equity_params = Map.take(params[:equity] || %{}, [:side, :quantity])
    option_params = Map.take(params[:option] || %{}, [:option_symbol, :side, :quantity])

    %{
      class: "combo",
      symbol: params[:symbol],
      type: params[:type],
      duration: params[:duration],
      price: params[:price]
    }
    |> Map.merge(equity_params)
    |> Map.merge(option_params)
  end
end
