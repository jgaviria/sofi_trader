defmodule SofiTrader.Kalshi.WebSocketManager do
  @moduledoc """
  Manages the Kalshi WebSocket connection for real-time market data.

  This GenServer:
  - Maintains ONE WebSocket connection for ALL Kalshi markets
  - Subscribes/unsubscribes tickers dynamically
  - Publishes updates via PubSub to kalshi:ticker:{ticker}, kalshi:orderbook:{ticker}
  - Handles reconnection with exponential backoff
  - Tracks subscription state per channel

  ## PubSub Topics

  Broadcasts are published to these topics:
  - `kalshi:ticker:{ticker}` - Price/volume updates
  - `kalshi:orderbook:{ticker}` - Orderbook changes
  - `kalshi:trade:{ticker}` - Trade notifications
  - `kalshi:fill:{ticker}` - Your order fills
  - `kalshi:position:{ticker}` - Position updates
  """

  use GenServer
  require Logger

  alias SofiTrader.Kalshi.WebSocket

  defstruct [
    :websocket_pid,
    :subscriptions,      # %{channel => MapSet.t(ticker)}
    :connected_at,
    :reconnect_count
  ]

  @reconnect_delay_ms 5000
  @channels ~w(ticker orderbook_delta trade fill market_positions)

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to ticker updates for a market.
  """
  def subscribe_ticker(ticker) do
    GenServer.call(__MODULE__, {:subscribe, "ticker", ticker})
  end

  @doc """
  Subscribe to orderbook updates for a market.
  """
  def subscribe_orderbook(ticker) do
    GenServer.call(__MODULE__, {:subscribe, "orderbook_delta", ticker})
  end

  @doc """
  Subscribe to trade notifications for a market.
  """
  def subscribe_trades(ticker) do
    GenServer.call(__MODULE__, {:subscribe, "trade", ticker})
  end

  @doc """
  Subscribe to multiple channels for a ticker at once.
  """
  def subscribe_all(ticker) do
    GenServer.call(__MODULE__, {:subscribe_all, ticker})
  end

  @doc """
  Unsubscribe from all channels for a ticker.
  """
  def unsubscribe(ticker) do
    GenServer.call(__MODULE__, {:unsubscribe_all, ticker})
  end

  @doc """
  Get current connection status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Check if API is configured.
  """
  def configured? do
    SofiTrader.Kalshi.Client.configured?()
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("[Kalshi WS Manager] Starting")

    if configured?() do
      send(self(), :connect)

      {:ok, %__MODULE__{
        websocket_pid: nil,
        subscriptions: init_subscriptions(),
        connected_at: nil,
        reconnect_count: 0
      }}
    else
      Logger.warning("[Kalshi WS Manager] API not configured - WebSocket disabled")
      {:ok, %__MODULE__{subscriptions: init_subscriptions()}}
    end
  end

  @impl true
  def handle_call({:subscribe, channel, ticker}, _from, state) do
    if state.websocket_pid && Process.alive?(state.websocket_pid) do
      WebSocket.subscribe(state.websocket_pid, channel, [ticker])
    end

    new_subs = add_subscription(state.subscriptions, channel, ticker)
    Logger.debug("[Kalshi WS Manager] Subscribed #{ticker} to #{channel}")

    {:reply, :ok, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_call({:subscribe_all, ticker}, _from, state) do
    channels = ["ticker", "orderbook_delta", "trade"]

    if state.websocket_pid && Process.alive?(state.websocket_pid) do
      Enum.each(channels, fn channel ->
        WebSocket.subscribe(state.websocket_pid, channel, [ticker])
      end)
    end

    new_subs = Enum.reduce(channels, state.subscriptions, fn ch, acc ->
      add_subscription(acc, ch, ticker)
    end)

    Logger.info("[Kalshi WS Manager] Subscribed #{ticker} to all channels")
    {:reply, :ok, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_call({:unsubscribe_all, ticker}, _from, state) do
    if state.websocket_pid && Process.alive?(state.websocket_pid) do
      Enum.each(@channels, fn channel ->
        WebSocket.unsubscribe(state.websocket_pid, channel, [ticker])
      end)
    end

    new_subs = Enum.reduce(@channels, state.subscriptions, fn ch, acc ->
      remove_subscription(acc, ch, ticker)
    end)

    Logger.info("[Kalshi WS Manager] Unsubscribed #{ticker} from all channels")
    {:reply, :ok, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connected: state.websocket_pid != nil && Process.alive?(state.websocket_pid),
      connected_at: state.connected_at,
      uptime_seconds: uptime_seconds(state.connected_at),
      subscriptions: format_subscriptions(state.subscriptions),
      reconnect_count: state.reconnect_count
    }
    {:reply, status, state}
  end

  @impl true
  def handle_info(:connect, state) do
    Logger.info("[Kalshi WS Manager] Attempting to connect...")

    case start_websocket() do
      {:ok, ws_pid} ->
        Process.monitor(ws_pid)

        # Resubscribe to all previous subscriptions
        resubscribe_all(ws_pid, state.subscriptions)

        new_state = %{state |
          websocket_pid: ws_pid,
          connected_at: DateTime.utc_now(),
          reconnect_count: 0
        }

        Logger.info("[Kalshi WS Manager] Connected successfully (PID: #{inspect(ws_pid)})")
        {:noreply, new_state}

      {:error, %WebSockex.RequestError{} = error} ->
        Logger.error("[Kalshi WS Manager] WebSocket request error: #{inspect(error)}")
        schedule_reconnect(state.reconnect_count)
        {:noreply, %{state | reconnect_count: state.reconnect_count + 1}}

      {:error, reason} ->
        Logger.error("[Kalshi WS Manager] Connection failed: #{inspect(reason)}")
        schedule_reconnect(state.reconnect_count)
        {:noreply, %{state | reconnect_count: state.reconnect_count + 1}}
    end
  end

  @impl true
  def handle_info({:websocket_event, channel, data}, state) do
    handle_channel_event(channel, data)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{websocket_pid: pid} = state) do
    Logger.warning("[Kalshi WS Manager] WebSocket died: #{inspect(reason)}")
    schedule_reconnect(state.reconnect_count)
    {:noreply, %{state | websocket_pid: nil, reconnect_count: state.reconnect_count + 1}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Kalshi WS Manager] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private Functions

  defp init_subscriptions do
    @channels
    |> Enum.map(fn ch -> {ch, MapSet.new()} end)
    |> Map.new()
  end

  defp add_subscription(subs, channel, ticker) do
    Map.update(subs, channel, MapSet.new([ticker]), fn set ->
      MapSet.put(set, ticker)
    end)
  end

  defp remove_subscription(subs, channel, ticker) do
    Map.update(subs, channel, MapSet.new(), fn set ->
      MapSet.delete(set, ticker)
    end)
  end

  defp format_subscriptions(subs) do
    subs
    |> Enum.map(fn {channel, set} -> {channel, MapSet.to_list(set)} end)
    |> Map.new()
  end

  defp start_websocket do
    # Create handlers that forward to this GenServer
    manager_pid = self()

    handlers = %{
      :ticker => fn data -> send(manager_pid, {:websocket_event, :ticker, data}) end,
      :orderbook_delta => fn data -> send(manager_pid, {:websocket_event, :orderbook_delta, data}) end,
      :trade => fn data -> send(manager_pid, {:websocket_event, :trade, data}) end,
      :fill => fn data -> send(manager_pid, {:websocket_event, :fill, data}) end,
      :market_positions => fn data -> send(manager_pid, {:websocket_event, :market_positions, data}) end
    }

    WebSocket.start_link(handlers: handlers)
  end

  defp resubscribe_all(ws_pid, subscriptions) do
    Enum.each(subscriptions, fn {channel, tickers} ->
      tickers_list = MapSet.to_list(tickers)
      if length(tickers_list) > 0 do
        WebSocket.subscribe(ws_pid, channel, tickers_list)
        Logger.debug("[Kalshi WS Manager] Resubscribed #{length(tickers_list)} tickers to #{channel}")
      end
    end)
  end

  defp schedule_reconnect(reconnect_count) do
    # Exponential backoff: 5s, 10s, 20s, 40s... max 60s
    delay = min(@reconnect_delay_ms * :math.pow(2, reconnect_count), 60_000) |> trunc()
    Logger.info("[Kalshi WS Manager] Reconnecting in #{delay}ms...")
    Process.send_after(self(), :connect, delay)
  end

  defp uptime_seconds(nil), do: 0
  defp uptime_seconds(connected_at) do
    DateTime.diff(DateTime.utc_now(), connected_at, :second)
  end

  # Channel Event Handlers - Broadcast to PubSub

  defp handle_channel_event(:ticker, %{"sid" => _sid, "msg" => msg}) do
    # Ticker message contains market ticker and price info
    ticker = msg["market_ticker"]
    if ticker do
      Phoenix.PubSub.broadcast(
        SofiTrader.PubSub,
        "kalshi:ticker:#{ticker}",
        {:ticker_update, parse_ticker(msg)}
      )
    end
  end

  defp handle_channel_event(:orderbook_delta, %{"sid" => _sid, "msg" => msg}) do
    ticker = msg["market_ticker"]
    if ticker do
      Phoenix.PubSub.broadcast(
        SofiTrader.PubSub,
        "kalshi:orderbook:#{ticker}",
        {:orderbook_update, parse_orderbook(msg)}
      )
    end
  end

  defp handle_channel_event(:trade, %{"sid" => _sid, "msg" => msg}) do
    ticker = msg["market_ticker"]
    if ticker do
      Phoenix.PubSub.broadcast(
        SofiTrader.PubSub,
        "kalshi:trade:#{ticker}",
        {:trade_update, parse_trade(msg)}
      )
    end
  end

  defp handle_channel_event(:fill, %{"sid" => _sid, "msg" => msg}) do
    ticker = msg["market_ticker"]
    if ticker do
      Phoenix.PubSub.broadcast(
        SofiTrader.PubSub,
        "kalshi:fill:#{ticker}",
        {:fill_update, msg}
      )

      # Also broadcast to general fills topic for strategy monitoring
      Phoenix.PubSub.broadcast(
        SofiTrader.PubSub,
        "kalshi:fills",
        {:fill_update, msg}
      )
    end
  end

  defp handle_channel_event(:market_positions, %{"sid" => _sid, "msg" => msg}) do
    ticker = msg["market_ticker"]
    if ticker do
      Phoenix.PubSub.broadcast(
        SofiTrader.PubSub,
        "kalshi:position:#{ticker}",
        {:position_update, msg}
      )
    end
  end

  defp handle_channel_event(channel, data) do
    Logger.debug("[Kalshi WS Manager] Unhandled #{channel} event: #{inspect(data)}")
  end

  # Parsers for normalizing WebSocket data

  defp parse_ticker(msg) do
    %{
      ticker: msg["market_ticker"],
      yes_bid: msg["yes_bid"],
      yes_ask: msg["yes_ask"],
      no_bid: msg["no_bid"],
      no_ask: msg["no_ask"],
      last_price: msg["last_price"],
      volume: msg["volume"],
      open_interest: msg["open_interest"],
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_orderbook(msg) do
    %{
      ticker: msg["market_ticker"],
      yes: msg["yes"] || [],
      no: msg["no"] || [],
      timestamp: DateTime.utc_now()
    }
  end

  defp parse_trade(msg) do
    %{
      ticker: msg["market_ticker"],
      side: msg["side"],
      count: msg["count"],
      price: msg["price"],
      yes_price: msg["yes_price"],
      no_price: msg["no_price"],
      timestamp: msg["ts"] || DateTime.utc_now()
    }
  end
end
