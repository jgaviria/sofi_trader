defmodule SofiTrader.MarketData.Candles do
  @moduledoc """
  Candlestick data aggregator.

  Aggregates trade data into OHLC candlesticks at specified intervals.
  """

  use GenServer
  require Logger

  alias SofiTrader.MarketData.Stream

  defstruct [:interval, :symbols, :candles, :current_candles, :subscribers]

  @doc """
  Start a new candles aggregator.

  ## Options
    - `:interval` - Candle interval in seconds (default: 60)
    - `:symbols` - List of symbols to track
    - `:name` - Name for the GenServer
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Subscribe to candle updates for symbols.
  """
  def subscribe(pid, symbols, subscriber_pid \\ nil) when is_list(symbols) do
    GenServer.call(pid, {:subscribe, symbols, subscriber_pid || self()})
  end

  @doc """
  Get current candle for a symbol.
  """
  def get_current_candle(pid, symbol) do
    GenServer.call(pid, {:get_current_candle, symbol})
  end

  @doc """
  Get historical candles for a symbol.
  """
  def get_candles(pid, symbol, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    GenServer.call(pid, {:get_candles, symbol, limit})
  end

  # GenServer Callbacks

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, 60) * 1000  # Convert to milliseconds
    symbols = Keyword.get(opts, :symbols, [])

    # Subscribe to market data stream
    if length(symbols) > 0 do
      Stream.subscribe(Stream, symbols)
    end

    # Schedule first candle close
    Process.send_after(self(), :close_candles, interval)

    state = %__MODULE__{
      interval: interval,
      symbols: symbols,
      candles: %{},
      current_candles: %{},
      subscribers: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:subscribe, symbols, subscriber_pid}, _from, state) do
    # Subscribe to market data stream
    Stream.subscribe(Stream, symbols, self())

    # Add subscriber
    new_subscribers =
      Enum.reduce(symbols, state.subscribers, fn symbol, acc ->
        subscribers_for_symbol = Map.get(acc, symbol, MapSet.new())
        Map.put(acc, symbol, MapSet.put(subscribers_for_symbol, subscriber_pid))
      end)

    new_state = %{
      state |
      symbols: Enum.uniq(state.symbols ++ symbols),
      subscribers: new_subscribers
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:get_current_candle, symbol}, _from, state) do
    candle = Map.get(state.current_candles, symbol)
    {:reply, candle, state}
  end

  @impl GenServer
  def handle_call({:get_candles, symbol, limit}, _from, state) do
    candles = Map.get(state.candles, symbol, [])
    limited_candles = Enum.take(candles, limit)
    {:reply, limited_candles, state}
  end

  @impl GenServer
  def handle_info({:market_data, "trade", symbol, data}, state) do
    price = parse_price(data["price"])
    volume = parse_volume(data["size"])
    timestamp = parse_timestamp(data["date"])

    new_state = update_candle(state, symbol, price, volume, timestamp)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:market_data, _type, _symbol, _data}, state) do
    # Ignore other market data types
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:close_candles, state) do
    new_state = close_all_candles(state)

    # Schedule next candle close
    Process.send_after(self(), :close_candles, state.interval)

    {:noreply, new_state}
  end

  # Private Functions

  defp update_candle(state, symbol, price, volume, timestamp) do
    current_candle =
      case Map.get(state.current_candles, symbol) do
        nil ->
          %{
            symbol: symbol,
            open: price,
            high: price,
            low: price,
            close: price,
            volume: volume,
            timestamp: timestamp
          }

        candle ->
          %{
            candle |
            high: max(candle.high, price),
            low: min(candle.low, price),
            close: price,
            volume: candle.volume + volume
          }
      end

    %{state | current_candles: Map.put(state.current_candles, symbol, current_candle)}
  end

  defp close_all_candles(state) do
    Enum.reduce(state.current_candles, state, fn {symbol, candle}, acc ->
      close_candle(acc, symbol, candle)
    end)
  end

  defp close_candle(state, symbol, candle) do
    # Add to historical candles
    historical = Map.get(state.candles, symbol, [])
    new_historical = [candle | historical] |> Enum.take(1000)  # Keep last 1000 candles

    # Broadcast to subscribers
    broadcast_candle(state, symbol, candle)

    # Clear current candle
    %{
      state |
      candles: Map.put(state.candles, symbol, new_historical),
      current_candles: Map.delete(state.current_candles, symbol)
    }
  end

  defp broadcast_candle(state, symbol, candle) do
    subscribers = Map.get(state.subscribers, symbol, MapSet.new())

    Enum.each(subscribers, fn subscriber_pid ->
      send(subscriber_pid, {:candle, symbol, candle})
    end)
  end

  defp parse_price(price) when is_binary(price) do
    {price_float, _} = Float.parse(price)
    price_float
  end

  defp parse_price(price) when is_number(price), do: price * 1.0

  defp parse_volume(volume) when is_binary(volume) do
    {volume_int, _} = Integer.parse(volume)
    volume_int
  end

  defp parse_volume(volume) when is_integer(volume), do: volume

  defp parse_timestamp(date) when is_integer(date), do: date
  defp parse_timestamp(_), do: System.system_time(:millisecond)
end
