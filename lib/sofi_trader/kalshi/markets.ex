defmodule SofiTrader.Kalshi.Markets do
  @moduledoc """
  Kalshi Markets API client.

  Provides functions for fetching market data, orderbooks, and events.
  """

  alias SofiTrader.Kalshi.Client

  @doc """
  Get a list of markets with optional filtering.

  ## Options
    - `:status` - Filter by status: "unopened", "open", "closed", "settled"
    - `:event_ticker` - Filter by event ticker
    - `:series_ticker` - Filter by series ticker
    - `:tickers` - List of specific market tickers
    - `:limit` - Number of results (1-1000, default 100)
    - `:cursor` - Pagination cursor from previous response

  ## Examples

      Markets.list_markets(status: "open", limit: 50)
      Markets.list_markets(event_ticker: "KXBTC")
  """
  def list_markets(opts \\ []) do
    params = build_market_params(opts)
    Client.get("/trade-api/v2/markets", params)
  end

  @doc """
  Get a specific market by ticker.

  ## Examples

      Markets.get_market("KXBTC-24DEC31-T100000")
  """
  def get_market(ticker) do
    Client.get("/trade-api/v2/markets/#{ticker}")
  end

  @doc """
  Get the orderbook for a specific market.

  Returns the current bids and asks with depth.

  ## Options
    - `:depth` - Number of price levels (default 10)
  """
  def get_orderbook(ticker, opts \\ []) do
    depth = Keyword.get(opts, :depth, 10)
    Client.get("/trade-api/v2/markets/#{ticker}/orderbook", depth: depth)
  end

  @doc """
  Get candlestick data for a market.

  ## Options
    - `:start_ts` - Start timestamp (Unix seconds)
    - `:end_ts` - End timestamp (Unix seconds)
    - `:period_interval` - Candle interval in minutes (1, 5, 15, 60, 1440)
  """
  def get_candlesticks(ticker, opts \\ []) do
    params = Keyword.take(opts, [:start_ts, :end_ts, :period_interval])
    Client.get("/trade-api/v2/markets/#{ticker}/candlesticks", params)
  end

  @doc """
  Get recent trades for a market.

  ## Options
    - `:limit` - Number of trades to return
    - `:cursor` - Pagination cursor
    - `:min_ts` - Minimum timestamp filter
    - `:max_ts` - Maximum timestamp filter
  """
  def get_trades(ticker, opts \\ []) do
    params = Keyword.take(opts, [:limit, :cursor, :min_ts, :max_ts])
    Client.get("/trade-api/v2/markets/#{ticker}/trades", params)
  end

  @doc """
  Get all events (collections of related markets).

  ## Options
    - `:status` - Filter by status
    - `:series_ticker` - Filter by series
    - `:limit` - Number of results
    - `:cursor` - Pagination cursor
  """
  def list_events(opts \\ []) do
    params = Keyword.take(opts, [:status, :series_ticker, :limit, :cursor])
    Client.get("/trade-api/v2/events", params)
  end

  @doc """
  Get a specific event by ticker.
  """
  def get_event(event_ticker) do
    Client.get("/trade-api/v2/events/#{event_ticker}")
  end

  @doc """
  Get all series (categories of events).
  """
  def list_series(opts \\ []) do
    params = Keyword.take(opts, [:limit, :cursor])
    Client.get("/trade-api/v2/series", params)
  end

  @doc """
  Get exchange status (useful for checking if trading is open).
  """
  def get_exchange_status do
    Client.get("/trade-api/v2/exchange/status")
  end

  # Private helpers

  defp build_market_params(opts) do
    base_params = Keyword.take(opts, [
      :status,
      :event_ticker,
      :series_ticker,
      :limit,
      :cursor,
      :min_close_ts,
      :max_close_ts
    ])

    # Handle tickers as comma-separated string
    case Keyword.get(opts, :tickers) do
      nil -> base_params
      tickers when is_list(tickers) ->
        Keyword.put(base_params, :tickers, Enum.join(tickers, ","))
      tickers ->
        Keyword.put(base_params, :tickers, tickers)
    end
  end
end
