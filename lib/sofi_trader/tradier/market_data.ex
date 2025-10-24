defmodule SofiTrader.Tradier.MarketData do
  @moduledoc """
  Market data operations for Tradier API.

  Provides functions to retrieve quotes, option chains, historical data, etc.
  """

  alias SofiTrader.Tradier.Client

  @doc """
  Get quotes for one or more symbols.

  ## Examples

      iex> MarketData.get_quotes("AAPL")
      {:ok, %{...}}

      iex> MarketData.get_quotes(["AAPL", "MSFT", "GOOGL"])
      {:ok, %{...}}
  """
  def get_quotes(symbols, opts \\ []) when is_binary(symbols) or is_list(symbols) do
    symbol_string = symbols_to_string(symbols)
    Client.get("/markets/quotes", [symbols: symbol_string], opts)
  end

  @doc """
  Get historical quotes for a symbol.
  """
  def get_history(symbol, opts \\ []) do
    params = build_history_params(opts)
    Client.get("/markets/history", [{:symbol, symbol} | params], opts)
  end

  @doc """
  Get time and sales (tick data) for a symbol.
  """
  def get_timesales(symbol, opts \\ []) do
    params = build_timesales_params(opts)
    Client.get("/markets/timesales", [{:symbol, symbol} | params], opts)
  end

  @doc """
  Get option chains for a symbol.
  """
  def get_option_chains(symbol, expiration, opts \\ []) do
    params = [symbol: symbol, expiration: expiration]
    params = maybe_add_param(params, :greeks, opts[:greeks])
    Client.get("/markets/options/chains", params, opts)
  end

  @doc """
  Get option strikes for a symbol and expiration.
  """
  def get_option_strikes(symbol, expiration, opts \\ []) do
    params = [symbol: symbol, expiration: expiration]
    Client.get("/markets/options/strikes", params, opts)
  end

  @doc """
  Get option expirations for a symbol.
  """
  def get_option_expirations(symbol, opts \\ []) do
    params = [symbol: symbol]
    params = maybe_add_param(params, :includeAllRoots, opts[:include_all_roots])
    params = maybe_add_param(params, :strikes, opts[:strikes])
    Client.get("/markets/options/expirations", params, opts)
  end

  @doc """
  Search for symbols.
  """
  def search(query, opts \\ []) do
    params = [q: query]
    params = maybe_add_param(params, :indexes, opts[:indexes])
    Client.get("/markets/search", params, opts)
  end

  @doc """
  Lookup symbol information.
  """
  def lookup(query, opts \\ []) do
    params = [q: query]
    params = maybe_add_param(params, :exchanges, opts[:exchanges])
    params = maybe_add_param(params, :types, opts[:types])
    Client.get("/markets/lookup", params, opts)
  end

  @doc """
  Get market calendar.
  """
  def get_calendar(opts \\ []) do
    params = []
    params = maybe_add_param(params, :month, opts[:month])
    params = maybe_add_param(params, :year, opts[:year])
    Client.get("/markets/calendar", params, opts)
  end

  @doc """
  Get market clock (current market status).
  """
  def get_clock(opts \\ []) do
    Client.get("/markets/clock", [], opts)
  end

  @doc """
  Request a streaming session for market data.
  """
  def create_stream_session(opts \\ []) do
    Client.post("/markets/events/session", %{}, opts)
  end

  defp symbols_to_string(symbols) when is_list(symbols), do: Enum.join(symbols, ",")
  defp symbols_to_string(symbol) when is_binary(symbol), do: symbol

  defp build_history_params(opts) do
    []
    |> maybe_add_param(:interval, opts[:interval])
    |> maybe_add_param(:start, opts[:start])
    |> maybe_add_param(:end, opts[:end])
  end

  defp build_timesales_params(opts) do
    []
    |> maybe_add_param(:interval, opts[:interval])
    |> maybe_add_param(:start, opts[:start])
    |> maybe_add_param(:end, opts[:end])
    |> maybe_add_param(:session_filter, opts[:session_filter])
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]
end
