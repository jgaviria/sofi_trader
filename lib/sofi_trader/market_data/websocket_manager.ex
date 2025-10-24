defmodule SofiTrader.MarketData.WebSocketManager do
  @moduledoc """
  Manages a single WebSocket connection to Tradier for real-time market data.

  This GenServer:
  - Creates a streaming session with Tradier
  - Maintains ONE WebSocket connection for ALL symbols
  - Subscribes/unsubscribes symbols dynamically
  - Publishes quote updates via PubSub to tradier:quote:[symbol]
  - Handles reconnection and session renewal

  Tradier restriction: Only ONE WebSocket session allowed per account.
  """

  use GenServer
  require Logger

  alias SofiTrader.Tradier.{MarketData, WebSocket}

  defstruct [
    :websocket_pid,
    :session_id,
    :token,
    :symbols,
    :session_created_at
  ]

  @session_ttl_minutes 30  # Recreate session every 30 minutes (sessions are short-lived)
  @reconnect_delay_ms 5000

  ## Client API

  @doc """
  Starts the WebSocket manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a symbol to receive real-time quotes.
  """
  def subscribe_symbol(symbol) do
    GenServer.call(__MODULE__, {:subscribe_symbol, symbol})
  end

  @doc """
  Unregisters a symbol (stops receiving quotes).
  """
  def unsubscribe_symbol(symbol) do
    GenServer.call(__MODULE__, {:unsubscribe_symbol, symbol})
  end

  @doc """
  Gets current connection status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting WebSocket Manager for Tradier streaming")

    token = System.get_env("TRADIER_ACCESS_TOKEN")

    if token do
      # Start connection process asynchronously
      send(self(), :connect)

      {:ok, %__MODULE__{
        websocket_pid: nil,
        session_id: nil,
        token: token,
        symbols: MapSet.new(),
        session_created_at: nil
      }}
    else
      Logger.error("TRADIER_ACCESS_TOKEN not found - WebSocket streaming disabled")
      {:ok, %__MODULE__{token: nil, symbols: MapSet.new()}}
    end
  end

  @impl true
  def handle_call({:subscribe_symbol, symbol}, _from, state) do
    if state.token do
      new_symbols = MapSet.put(state.symbols, symbol)

      # If WebSocket is connected, subscribe to the new symbol
      if state.websocket_pid && Process.alive?(state.websocket_pid) do
        WebSocket.subscribe(state.websocket_pid, [symbol])
      end

      Logger.info("WebSocketManager: Subscribed to #{symbol} (#{MapSet.size(new_symbols)} total symbols)")
      {:reply, :ok, %{state | symbols: new_symbols}}
    else
      {:reply, {:error, :no_token}, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe_symbol, symbol}, _from, state) do
    new_symbols = MapSet.delete(state.symbols, symbol)

    # If WebSocket is connected, unsubscribe from the symbol
    if state.websocket_pid && Process.alive?(state.websocket_pid) do
      WebSocket.unsubscribe(state.websocket_pid, [symbol])
    end

    Logger.info("WebSocketManager: Unsubscribed from #{symbol} (#{MapSet.size(new_symbols)} total symbols)")
    {:reply, :ok, %{state | symbols: new_symbols}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connected: state.websocket_pid != nil && Process.alive?(state.websocket_pid),
      session_id: state.session_id,
      symbols: MapSet.to_list(state.symbols),
      symbol_count: MapSet.size(state.symbols),
      session_age_minutes: session_age_minutes(state.session_created_at)
    }
    {:reply, status, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case create_session_and_connect(state) do
      {:ok, new_state} ->
        # Schedule session renewal
        schedule_session_renewal()
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to connect WebSocket: #{inspect(reason)}")
        # Retry connection
        Process.send_after(self(), :connect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:renew_session, state) do
    Logger.info("Renewing WebSocket session (age: #{session_age_minutes(state.session_created_at)} minutes)")

    # Close old WebSocket
    if state.websocket_pid && Process.alive?(state.websocket_pid) do
      GenServer.stop(state.websocket_pid, :normal)
    end

    # Create new session and reconnect
    send(self(), :connect)
    {:noreply, %{state | websocket_pid: nil, session_id: nil}}
  end

  @impl true
  def handle_info({:websocket_event, event}, state) do
    handle_market_event(event)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{websocket_pid: pid} = state) do
    Logger.warning("WebSocket connection died: #{inspect(reason)}")

    # Reconnect after delay
    Process.send_after(self(), :connect, @reconnect_delay_ms)
    {:noreply, %{state | websocket_pid: nil}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("WebSocketManager received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private Functions

  defp create_session_and_connect(state) do
    with {:ok, session_response} <- MarketData.create_stream_session(token: state.token),
         session_id <- extract_session_id(session_response),
         {:ok, ws_pid} <- start_websocket(session_id, state.token) do

      # Monitor the WebSocket process
      Process.monitor(ws_pid)

      new_state = %{state |
        websocket_pid: ws_pid,
        session_id: session_id,
        session_created_at: DateTime.utc_now()
      }

      # Subscribe to all current symbols
      if MapSet.size(state.symbols) > 0 do
        symbols_list = MapSet.to_list(state.symbols)
        WebSocket.subscribe(ws_pid, symbols_list)
        Logger.info("WebSocketManager: Connected and subscribed to #{length(symbols_list)} symbols")
      else
        Logger.info("WebSocketManager: Connected (no symbols yet)")
      end

      {:ok, new_state}
    else
      error ->
        Logger.error("Failed to create session or connect: #{inspect(error)}")
        error
    end
  end

  defp start_websocket(session_id, token) do
    # Create event handler that sends messages to this GenServer
    handler = fn event ->
      send(__MODULE__, {:websocket_event, event})
    end

    handlers = %{
      "quote" => handler,
      "trade" => handler,
      "summary" => handler
    }

    WebSocket.start_link(
      session_id: session_id,
      token: token,
      filter: ["quote", "trade"],
      handlers: handlers,
      symbols: []
    )
  end

  defp extract_session_id(%{"stream" => %{"sessionid" => session_id}}), do: session_id
  defp extract_session_id(response) do
    Logger.error("Unexpected session response: #{inspect(response)}")
    nil
  end

  defp handle_market_event(%{"type" => "quote", "symbol" => symbol} = event) do
    # Publish quote to PubSub for CandleAggregators to consume
    Phoenix.PubSub.broadcast(
      SofiTrader.PubSub,
      "tradier:quote:#{symbol}",
      {:quote_update, extract_quote_data(event)}
    )
  end

  defp handle_market_event(%{"type" => "trade", "symbol" => symbol} = event) do
    # Publish trade to PubSub
    Phoenix.PubSub.broadcast(
      SofiTrader.PubSub,
      "tradier:quote:#{symbol}",
      {:trade_update, extract_trade_data(event)}
    )
  end

  defp handle_market_event(event) do
    Logger.debug("Unhandled market event: #{inspect(event)}")
  end

  defp extract_quote_data(event) do
    %{
      symbol: event["symbol"],
      last: event["last"],
      bid: event["bid"],
      ask: event["ask"],
      bidsize: event["bidsize"],
      asksize: event["asksize"],
      volume: event["volume"],
      timestamp: event["timestamp"] || DateTime.utc_now()
    }
  end

  defp extract_trade_data(event) do
    %{
      symbol: event["symbol"],
      price: event["price"],
      size: event["size"],
      timestamp: event["timestamp"] || DateTime.utc_now()
    }
  end

  defp schedule_session_renewal do
    Process.send_after(self(), :renew_session, @session_ttl_minutes * 60 * 1000)
  end

  defp session_age_minutes(nil), do: 0
  defp session_age_minutes(created_at) do
    DateTime.diff(DateTime.utc_now(), created_at, :second) / 60
    |> Float.round(1)
  end
end
