defmodule SofiTrader.MarketData.CandleAggregator do
  @moduledoc """
  Aggregates real-time market data into candles and publishes them via PubSub.

  This GenServer receives real-time quotes from WebSocketManager and builds candles
  based on the configured timeframe (1min, 5min, 15min, etc.).
  """
  use GenServer
  require Logger

  alias SofiTrader.MarketData.WebSocketManager
  alias SofiTrader.MarketData.PriceStore

  defstruct [
    :symbol,
    :timeframe_minutes,
    :current_candle,
    :last_update_time,
    :price_history,
    :mode  # :websocket or :polling
  ]

  @fetch_interval_ms 10_000  # Poll every 10 seconds for REST mode

  # Client API

  def start_link(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    timeframe_minutes = Keyword.get(opts, :timeframe_minutes, 5)

    GenServer.start_link(__MODULE__, opts,
      name: via_tuple(symbol, timeframe_minutes)
    )
  end

  def stop(symbol, timeframe_minutes) do
    case Registry.lookup(SofiTrader.MarketDataRegistry, {symbol, timeframe_minutes}) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> {:error, :not_found}
    end
  end

  defp via_tuple(symbol, timeframe_minutes) do
    {:via, Registry, {SofiTrader.MarketDataRegistry, {symbol, timeframe_minutes}}}
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    timeframe_minutes = Keyword.get(opts, :timeframe_minutes, 5)
    mode = Keyword.get(opts, :mode, default_mode())

    Logger.info("Starting Candle Aggregator for #{symbol} (#{timeframe_minutes}min) in #{mode} mode")

    # Setup based on mode
    case mode do
      :websocket ->
        # Subscribe to WebSocket quotes for this symbol
        Phoenix.PubSub.subscribe(SofiTrader.PubSub, "tradier:quote:#{symbol}")

        # Try to register with WebSocketManager if it's running
        if websocket_manager_available?() do
          WebSocketManager.subscribe_symbol(symbol)
        else
          Logger.warning("WebSocketManager not available, falling back to polling mode")
          # Schedule first fetch
          Process.send_after(self(), :fetch_market_data, 1000)
        end

      :polling ->
        # Schedule first fetch
        Process.send_after(self(), :fetch_market_data, 1000)
    end

    state = %__MODULE__{
      symbol: symbol,
      timeframe_minutes: timeframe_minutes,
      current_candle: nil,
      last_update_time: nil,
      price_history: [],
      mode: mode
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:quote_update, quote_data}, state) do
    # Real-time quote from WebSocket
    new_state = process_quote_update(quote_data, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:trade_update, trade_data}, state) do
    # Real-time trade from WebSocket
    new_state = process_trade_update(trade_data, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:fetch_market_data, state) do
    # REST API polling mode
    case fetch_current_quote(state.symbol) do
      {:ok, quote_data} ->
        new_state = process_quote_update(quote_data, state)
        # Schedule next fetch
        Process.send_after(self(), :fetch_market_data, @fetch_interval_ms)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("Failed to fetch quote for #{state.symbol}: #{inspect(reason)}")
        # Retry after interval
        Process.send_after(self(), :fetch_market_data, @fetch_interval_ms)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Unregister from WebSocketManager when stopping
    if state.mode == :websocket && websocket_manager_available?() do
      WebSocketManager.unsubscribe_symbol(state.symbol)
    end
    :ok
  end

  # Private Functions

  defp process_quote_update(quote_data, state) do
    price = extract_price_from_quote(quote_data)
    timestamp = quote_data.timestamp || DateTime.utc_now()

    if price do
      state = update_price_history(state, price)
      state = maybe_start_new_candle(state, timestamp, price)
      state = update_current_candle(state, price)
      maybe_close_candle(state, timestamp)
    else
      state
    end
  end

  defp process_trade_update(trade_data, state) do
    price = trade_data.price
    timestamp = trade_data.timestamp || DateTime.utc_now()

    if price && price > 0 do
      state = update_price_history(state, price)
      state = maybe_start_new_candle(state, timestamp, price)
      state = update_current_candle(state, price)
      maybe_close_candle(state, timestamp)
    else
      state
    end
  end

  defp extract_price_from_quote(quote_data) do
    # Try last price, then bid/ask midpoint
    cond do
      is_number(quote_data.last) && quote_data.last > 0 ->
        quote_data.last

      is_number(quote_data.bid) && is_number(quote_data.ask) ->
        (quote_data.bid + quote_data.ask) / 2

      true ->
        nil
    end
  end

  defp update_price_history(state, price) do
    # Keep last 200 prices for technical indicators in local state
    price_history = [price | state.price_history] |> Enum.take(200)

    # Also store in shared ETS for fast concurrent access
    PriceStore.add_price(state.symbol, price)

    %{state | price_history: price_history}
  end

  defp maybe_start_new_candle(state, timestamp, price) do
    if state.current_candle == nil do
      candle = %{
        symbol: state.symbol,
        timeframe: "#{state.timeframe_minutes}min",
        open: price,
        high: price,
        low: price,
        close: price,
        volume: 0,
        start_time: candle_start_time(timestamp, state.timeframe_minutes),
        end_time: candle_end_time(timestamp, state.timeframe_minutes)
      }

      %{state | current_candle: candle}
    else
      state
    end
  end

  defp update_current_candle(state, price) do
    if state.current_candle do
      candle = state.current_candle
      candle = %{candle |
        high: max(candle.high, price),
        low: min(candle.low, price),
        close: price
      }

      %{state | current_candle: candle}
    else
      state
    end
  end

  defp maybe_close_candle(state, timestamp) do
    if state.current_candle do
      candle_end = state.current_candle.end_time

      if DateTime.compare(timestamp, candle_end) != :lt do
        # Candle period has ended, publish it
        publish_candle(state.symbol, state.current_candle, state.price_history)

        # Start new candle
        %{state | current_candle: nil}
      else
        state
      end
    else
      state
    end
  end

  defp candle_start_time(timestamp, timeframe_minutes) do
    # Round down to the nearest timeframe interval
    unix = DateTime.to_unix(timestamp, :second)
    interval_seconds = timeframe_minutes * 60
    rounded_unix = div(unix, interval_seconds) * interval_seconds
    DateTime.from_unix!(rounded_unix)
  end

  defp candle_end_time(timestamp, timeframe_minutes) do
    start_time = candle_start_time(timestamp, timeframe_minutes)
    DateTime.add(start_time, timeframe_minutes * 60, :second)
  end

  defp publish_candle(symbol, candle, price_history) do
    Logger.info("Publishing candle for #{symbol}: O=#{candle.open} H=#{candle.high} L=#{candle.low} C=#{candle.close}")

    # Store candle in shared ETS for fast concurrent access
    PriceStore.put_candle(symbol, candle.timeframe, candle)

    # Store price history snapshot in ETS
    PriceStore.put_price_history(symbol, price_history)

    # Broadcast via PubSub for real-time subscribers
    message = {:candle_closed, candle, price_history}
    Phoenix.PubSub.broadcast(
      SofiTrader.PubSub,
      "market_data:#{symbol}",
      message
    )
  end

  defp fetch_current_quote(symbol) do
    alias SofiTrader.Tradier.MarketData

    case MarketData.get_quotes(symbol) do
      {:ok, %{"quotes" => %{"quote" => quote}}} ->
        # Convert REST API response to same format as WebSocket
        {:ok, %{
          symbol: quote["symbol"],
          last: quote["last"],
          bid: quote["bid"],
          ask: quote["ask"],
          bidsize: quote["bidsize"],
          asksize: quote["asksize"],
          volume: quote["volume"],
          timestamp: DateTime.utc_now()
        }}

      {:error, _} = error ->
        error
    end
  end

  defp default_mode do
    # Use polling for sandbox, websocket for production
    config = Application.get_env(:sofi_trader, :tradier, [])
    sandbox = Keyword.get(config, :sandbox, true)

    if sandbox, do: :polling, else: :websocket
  end

  defp websocket_manager_available? do
    case Process.whereis(WebSocketManager) do
      nil -> false
      _pid -> true
    end
  end
end
