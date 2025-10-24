defmodule SofiTrader.MarketData.Stream do
  @moduledoc """
  Base module for market data streaming.

  Provides common functionality for all market data streams.
  """

  use GenServer
  require Logger

  alias SofiTrader.Tradier.{MarketData, WebSocket}

  defstruct [:session_id, :websocket_pid, :symbols, :subscribers, :token]

  @doc """
  Start a new market data stream.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Subscribe to a stream for specific symbols.
  """
  def subscribe(pid, symbols, subscriber_pid \\ nil) when is_list(symbols) do
    GenServer.call(pid, {:subscribe, symbols, subscriber_pid || self()})
  end

  @doc """
  Unsubscribe from symbols.
  """
  def unsubscribe(pid, symbols, subscriber_pid \\ nil) when is_list(symbols) do
    GenServer.call(pid, {:unsubscribe, symbols, subscriber_pid || self()})
  end

  # GenServer Callbacks

  @impl GenServer
  def init(opts) do
    token = Keyword.get(opts, :token) || System.get_env("TRADIER_ACCESS_TOKEN")

    # Create a streaming session
    case MarketData.create_stream_session(token: token) do
      {:ok, %{"stream" => %{"sessionid" => session_id}}} ->
        state = %__MODULE__{
          session_id: session_id,
          symbols: [],
          subscribers: %{},
          token: token
        }

        # Start WebSocket connection
        websocket_opts = [
          session_id: session_id,
          token: token,
          handlers: %{
            "trade" => &__MODULE__.handle_trade/1,
            "quote" => &__MODULE__.handle_quote/1,
            "summary" => &__MODULE__.handle_summary/1,
            "timesale" => &__MODULE__.handle_timesale/1
          }
        ]

        case WebSocket.start_link(websocket_opts) do
          {:ok, websocket_pid} ->
            state = %{state | websocket_pid: websocket_pid}
            {:ok, state}

          {:error, error} ->
            Logger.error("Failed to start WebSocket: #{inspect(error)}")
            {:stop, error}
        end

      {:error, error} ->
        Logger.error("Failed to create streaming session: #{inspect(error)}")
        {:stop, error}
    end
  end

  @impl GenServer
  def handle_call({:subscribe, symbols, subscriber_pid}, _from, state) do
    # Add subscriber to the list
    new_subscribers =
      Enum.reduce(symbols, state.subscribers, fn symbol, acc ->
        subscribers_for_symbol = Map.get(acc, symbol, MapSet.new())
        Map.put(acc, symbol, MapSet.put(subscribers_for_symbol, subscriber_pid))
      end)

    # Subscribe to WebSocket
    WebSocket.subscribe(state.websocket_pid, symbols)

    new_state = %{
      state |
      symbols: Enum.uniq(state.symbols ++ symbols),
      subscribers: new_subscribers
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:unsubscribe, symbols, subscriber_pid}, _from, state) do
    # Remove subscriber from the list
    new_subscribers =
      Enum.reduce(symbols, state.subscribers, fn symbol, acc ->
        subscribers_for_symbol = Map.get(acc, symbol, MapSet.new())
        updated_subscribers = MapSet.delete(subscribers_for_symbol, subscriber_pid)

        if MapSet.size(updated_subscribers) == 0 do
          Map.delete(acc, symbol)
        else
          Map.put(acc, symbol, updated_subscribers)
        end
      end)

    # Check if we should unsubscribe from WebSocket
    symbols_to_unsubscribe =
      Enum.filter(symbols, fn symbol ->
        not Map.has_key?(new_subscribers, symbol)
      end)

    if length(symbols_to_unsubscribe) > 0 do
      WebSocket.unsubscribe(state.websocket_pid, symbols_to_unsubscribe)
    end

    new_state = %{
      state |
      symbols: state.symbols -- symbols_to_unsubscribe,
      subscribers: new_subscribers
    }

    {:reply, :ok, new_state}
  end

  # Event Handlers (to be called by WebSocket)

  def handle_trade(data) do
    broadcast_to_subscribers(data, "trade")
  end

  def handle_quote(data) do
    broadcast_to_subscribers(data, "quote")
  end

  def handle_summary(data) do
    broadcast_to_subscribers(data, "summary")
  end

  def handle_timesale(data) do
    broadcast_to_subscribers(data, "timesale")
  end

  defp broadcast_to_subscribers(data, event_type) do
    symbol = data["symbol"]

    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        GenServer.cast(pid, {:broadcast, symbol, event_type, data})
    end
  end

  @impl GenServer
  def handle_cast({:broadcast, symbol, event_type, data}, state) do
    subscribers = Map.get(state.subscribers, symbol, MapSet.new())

    Enum.each(subscribers, fn subscriber_pid ->
      send(subscriber_pid, {:market_data, event_type, symbol, data})
    end)

    {:noreply, state}
  end
end
