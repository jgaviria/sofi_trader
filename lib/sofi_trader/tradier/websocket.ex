defmodule SofiTrader.Tradier.WebSocket do
  @moduledoc """
  WebSocket client for Tradier streaming API.

  Handles real-time market data streaming including quotes, trades, and summaries.
  """

  use WebSockex
  require Logger

  @stream_url "wss://ws.tradier.com/v1/markets/events"

  defstruct [:session_id, :symbols, :filter, :handlers, :token]

  @doc """
  Start a new WebSocket connection to Tradier streaming API.

  ## Options
    - `:session_id` - Session ID from create_stream_session
    - `:symbols` - List of symbols to subscribe to
    - `:filter` - List of event types (trade, quote, summary, timesale, tradex)
    - `:handlers` - Map of event handlers %{event_type => function}
    - `:token` - Tradier access token
  """
  def start_link(opts) do
    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      symbols: Keyword.get(opts, :symbols, []),
      filter: Keyword.get(opts, :filter, ["trade", "quote"]),
      handlers: Keyword.get(opts, :handlers, %{}),
      token: Keyword.get(opts, :token)
    }

    url = build_url(state.session_id)
    WebSockex.start_link(url, __MODULE__, state, name: opts[:name])
  end

  @doc """
  Subscribe to symbols.
  """
  def subscribe(pid, symbols) when is_list(symbols) do
    WebSockex.cast(pid, {:subscribe, symbols})
  end

  @doc """
  Unsubscribe from symbols.
  """
  def unsubscribe(pid, symbols) when is_list(symbols) do
    WebSockex.cast(pid, {:unsubscribe, symbols})
  end

  @doc """
  Update event filter.
  """
  def set_filter(pid, filter) when is_list(filter) do
    WebSockex.cast(pid, {:set_filter, filter})
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.info("Connected to Tradier WebSocket")

    # Subscribe to initial symbols if provided
    if length(state.symbols) > 0 do
      send(self(), {:subscribe, state.symbols})
    end

    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, data} ->
        handle_message(data, state)
        {:ok, state}

      {:error, error} ->
        Logger.error("Failed to decode message: #{inspect(error)}")
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_frame({:ping, _}, state) do
    {:reply, {:pong, ""}, state}
  end

  @impl WebSockex
  def handle_cast({:subscribe, symbols}, state) do
    message = %{
      symbols: symbols,
      filter: state.filter,
      sessionid: state.session_id
    }

    frame = {:text, Jason.encode!(message)}
    new_state = %{state | symbols: Enum.uniq(state.symbols ++ symbols)}
    {:reply, frame, new_state}
  end

  @impl WebSockex
  def handle_cast({:unsubscribe, symbols}, state) do
    # Remove symbols from subscription
    remaining_symbols = state.symbols -- symbols

    # Send empty message for the symbols we're unsubscribing
    message = %{
      symbols: remaining_symbols,
      filter: state.filter,
      sessionid: state.session_id
    }

    frame = {:text, Jason.encode!(message)}
    new_state = %{state | symbols: remaining_symbols}
    {:reply, frame, new_state}
  end

  @impl WebSockex
  def handle_cast({:set_filter, filter}, state) do
    message = %{
      symbols: state.symbols,
      filter: filter,
      sessionid: state.session_id
    }

    frame = {:text, Jason.encode!(message)}
    new_state = %{state | filter: filter}
    {:reply, frame, new_state}
  end

  @impl WebSockex
  def handle_info({:subscribe, symbols}, state) do
    handle_cast({:subscribe, symbols}, state)
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("Disconnected from Tradier WebSocket: #{inspect(reason)}")
    {:reconnect, state}
  end

  @impl WebSockex
  def terminate(reason, _state) do
    Logger.info("WebSocket terminating: #{inspect(reason)}")
    :ok
  end

  # Private Functions

  defp build_url(session_id) do
    "#{@stream_url}?sessionid=#{session_id}"
  end

  defp handle_message(%{"type" => type} = data, state) do
    # Call registered handler if exists
    case Map.get(state.handlers, type) do
      nil ->
        Logger.debug("Received #{type} event: #{inspect(data)}")

      handler when is_function(handler, 1) ->
        handler.(data)

      {module, function} ->
        apply(module, function, [data])
    end
  end

  defp handle_message(data, _state) do
    Logger.debug("Received unknown message: #{inspect(data)}")
  end
end
