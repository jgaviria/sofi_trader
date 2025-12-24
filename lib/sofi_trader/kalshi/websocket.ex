defmodule SofiTrader.Kalshi.WebSocket do
  @moduledoc """
  WebSocket client for Kalshi real-time market data.

  Supports subscribing to:
  - `orderbook_delta` - Real-time orderbook updates
  - `ticker` - Price, volume, and open interest
  - `trade` - Public trade notifications
  - `fill` - Your order fills (authenticated)
  - `market_positions` - Your position updates (authenticated)
  - `market_lifecycle_v2` - Market state changes

  ## Architecture

  This module is designed to be used via `SofiTrader.Kalshi.WebSocketManager`
  which handles connection lifecycle, subscriptions, and broadcasts to PubSub.
  """

  use WebSockex
  require Logger

  alias SofiTrader.Kalshi.Client

  defstruct [
    :subscriptions,    # MapSet of {channel, ticker} tuples
    :handlers,         # %{channel => handler_fn}
    :authenticated,    # Boolean - whether auth was successful
    :last_ping,        # Last ping timestamp
    :reconnect_count   # Number of reconnection attempts
  ]

  @heartbeat_interval 10_000  # 10 seconds
  @channels ~w(orderbook_delta ticker trade fill market_positions market_lifecycle_v2)

  @doc """
  Start a WebSocket connection to Kalshi.

  ## Options
    - `:name` - Process name for registration
    - `:handlers` - Map of channel => handler function
  """
  def start_link(opts \\ []) do
    state = %__MODULE__{
      subscriptions: MapSet.new(),
      handlers: Keyword.get(opts, :handlers, %{}),
      authenticated: false,
      last_ping: nil,
      reconnect_count: 0
    }

    url = get_websocket_url()

    # Build websocket options, only include name if provided
    websocket_opts = [extra_headers: build_auth_headers()]
    websocket_opts = case Keyword.get(opts, :name) do
      nil -> websocket_opts
      name -> [{:name, name} | websocket_opts]
    end

    Logger.info("[Kalshi WS] Connecting to #{url}")
    WebSockex.start_link(url, __MODULE__, state, websocket_opts)
  end

  @doc """
  Subscribe to a channel for specific tickers.

  ## Channels
    - `:orderbook_delta` - Orderbook updates
    - `:ticker` - Price/volume updates
    - `:trade` - Trade notifications

  ## Examples

      WebSocket.subscribe(pid, :ticker, ["KXBTC-24DEC31-T100000"])
      WebSocket.subscribe(pid, :orderbook_delta, ["KXBTC-24DEC31-T100000"])
  """
  def subscribe(pid, channel, tickers) when channel in @channels and is_list(tickers) do
    WebSockex.cast(pid, {:subscribe, to_string(channel), tickers})
  end

  def subscribe(pid, channel, ticker) when is_binary(ticker) do
    subscribe(pid, channel, [ticker])
  end

  @doc """
  Unsubscribe from a channel for specific tickers.
  """
  def unsubscribe(pid, channel, tickers) when is_list(tickers) do
    WebSockex.cast(pid, {:unsubscribe, to_string(channel), tickers})
  end

  def unsubscribe(pid, channel, ticker) when is_binary(ticker) do
    unsubscribe(pid, channel, [ticker])
  end

  @doc """
  Get current subscription state.
  """
  def get_subscriptions(pid) do
    WebSockex.cast(pid, {:get_subscriptions, self()})
    receive do
      {:subscriptions, subs} -> subs
    after
      5000 -> {:error, :timeout}
    end
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.info("[Kalshi WS] Connected to Kalshi WebSocket")

    # Start heartbeat timer
    Process.send_after(self(), :send_heartbeat, @heartbeat_interval)

    {:ok, %{state | authenticated: true, reconnect_count: 0}}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, data} ->
        handle_message(data, state)

      {:error, error} ->
        Logger.error("[Kalshi WS] Failed to decode: #{inspect(error)}")
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_frame({:ping, payload}, state) do
    Logger.debug("[Kalshi WS] Received ping")
    {:reply, {:pong, payload}, %{state | last_ping: System.system_time(:second)}}
  end

  @impl WebSockex
  def handle_frame({:pong, _payload}, state) do
    Logger.debug("[Kalshi WS] Received pong")
    {:ok, state}
  end

  @impl WebSockex
  def handle_cast({:subscribe, channel, tickers}, state) do
    message = %{
      id: generate_msg_id(),
      cmd: "subscribe",
      params: %{
        channels: [channel],
        market_tickers: tickers
      }
    }

    frame = {:text, Jason.encode!(message)}

    # Track subscriptions
    new_subs = Enum.reduce(tickers, state.subscriptions, fn ticker, acc ->
      MapSet.put(acc, {channel, ticker})
    end)

    Logger.debug("[Kalshi WS] Subscribing to #{channel} for #{inspect(tickers)}")
    {:reply, frame, %{state | subscriptions: new_subs}}
  end

  @impl WebSockex
  def handle_cast({:unsubscribe, channel, tickers}, state) do
    message = %{
      id: generate_msg_id(),
      cmd: "unsubscribe",
      params: %{
        channels: [channel],
        market_tickers: tickers
      }
    }

    frame = {:text, Jason.encode!(message)}

    # Remove from tracking
    new_subs = Enum.reduce(tickers, state.subscriptions, fn ticker, acc ->
      MapSet.delete(acc, {channel, ticker})
    end)

    Logger.debug("[Kalshi WS] Unsubscribing from #{channel} for #{inspect(tickers)}")
    {:reply, frame, %{state | subscriptions: new_subs}}
  end

  @impl WebSockex
  def handle_cast({:get_subscriptions, from}, state) do
    send(from, {:subscriptions, state.subscriptions})
    {:ok, state}
  end

  @impl WebSockex
  def handle_info(:send_heartbeat, state) do
    # Send ping frame
    Process.send_after(self(), :send_heartbeat, @heartbeat_interval)
    {:reply, {:ping, "heartbeat"}, state}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("[Kalshi WS] Disconnected: #{inspect(reason)}")

    # Exponential backoff for reconnection
    backoff = min(5000 * :math.pow(2, state.reconnect_count), 60_000) |> trunc()
    Logger.info("[Kalshi WS] Reconnecting in #{backoff}ms...")

    Process.sleep(backoff)
    {:reconnect, %{state | reconnect_count: state.reconnect_count + 1}}
  end

  @impl WebSockex
  def terminate(reason, state) do
    Logger.info("[Kalshi WS] Terminating: #{inspect(reason)}, had #{MapSet.size(state.subscriptions)} subscriptions")
    :ok
  end

  # Private Functions

  defp get_websocket_url do
    config = Application.get_env(:sofi_trader, :kalshi, [])
    demo = Keyword.get(config, :demo, true)

    if demo do
      Keyword.get(config, :demo_websocket_url, "wss://demo-api.kalshi.co/trade-api/ws/v2")
    else
      Keyword.get(config, :websocket_url, "wss://api.elections.kalshi.com/trade-api/ws/v2")
    end
  end

  defp build_auth_headers do
    timestamp = System.system_time(:millisecond)
    path = "/trade-api/ws/v2"

    api_key = System.get_env("KALSHI_API_KEY") || ""
    signature = if api_key != "" do
      Client.sign_request(:get, path, timestamp, "")
    else
      ""
    end

    [
      {"KALSHI-ACCESS-KEY", api_key},
      {"KALSHI-ACCESS-SIGNATURE", signature},
      {"KALSHI-ACCESS-TIMESTAMP", to_string(timestamp)}
    ]
  end

  defp generate_msg_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp handle_message(%{"type" => "subscribed", "msg" => msg}, state) do
    Logger.info("[Kalshi WS] Subscribed: #{inspect(msg)}")
    {:ok, state}
  end

  defp handle_message(%{"type" => "unsubscribed", "msg" => msg}, state) do
    Logger.info("[Kalshi WS] Unsubscribed: #{inspect(msg)}")
    {:ok, state}
  end

  defp handle_message(%{"type" => "error", "msg" => msg}, state) do
    Logger.error("[Kalshi WS] Error: #{inspect(msg)}")
    {:ok, state}
  end

  # Orderbook snapshot
  defp handle_message(%{"type" => "orderbook_snapshot"} = data, state) do
    invoke_handler(:orderbook_delta, data, state)
  end

  # Orderbook delta
  defp handle_message(%{"type" => "orderbook_delta"} = data, state) do
    invoke_handler(:orderbook_delta, data, state)
  end

  # Ticker update
  defp handle_message(%{"type" => "ticker"} = data, state) do
    invoke_handler(:ticker, data, state)
  end

  # Trade notification
  defp handle_message(%{"type" => "trade"} = data, state) do
    invoke_handler(:trade, data, state)
  end

  # Fill notification (user's orders)
  defp handle_message(%{"type" => "fill"} = data, state) do
    invoke_handler(:fill, data, state)
  end

  # Position update
  defp handle_message(%{"type" => "market_positions"} = data, state) do
    invoke_handler(:market_positions, data, state)
  end

  # Market lifecycle events
  defp handle_message(%{"type" => "market_lifecycle"} = data, state) do
    invoke_handler(:market_lifecycle_v2, data, state)
  end

  defp handle_message(data, state) do
    Logger.debug("[Kalshi WS] Unknown message: #{inspect(data)}")
    {:ok, state}
  end

  defp invoke_handler(channel, data, state) do
    case Map.get(state.handlers, channel) do
      nil ->
        Logger.debug("[Kalshi WS] #{channel}: #{inspect(data)}")

      handler when is_function(handler, 1) ->
        handler.(data)

      {module, function} ->
        apply(module, function, [data])
    end

    {:ok, state}
  end
end
