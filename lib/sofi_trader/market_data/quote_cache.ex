defmodule SofiTrader.MarketData.QuoteCache do
  @moduledoc """
  Centralized quote cache that fetches market quotes and broadcasts updates via PubSub.

  This GenServer:
  - Maintains a cache of recent quotes for watched symbols
  - Fetches quotes periodically (10s intervals)
  - Broadcasts quote updates via PubSub
  - Allows dynamic symbol subscription/unsubscription
  - Automatically cleans up unused symbols
  """
  use GenServer
  require Logger

  alias SofiTrader.Tradier.MarketData
  alias SofiTrader.MarketData.PriceStore

  @fetch_interval_ms 10_000  # Fetch every 10 seconds
  @cleanup_interval_ms 300_000  # Check for unused symbols every 5 minutes
  @symbol_ttl_ms 600_000  # Remove symbol if not subscribed for 10 minutes

  defstruct [
    :quotes,              # %{symbol => quote_data}
    :symbols,             # MapSet of actively watched symbols
    :symbol_subscribers,  # %{symbol => MapSet of subscriber_pids}
    :last_fetched         # %{symbol => timestamp}
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to real-time quotes for a symbol.
  Returns current quote if available.
  """
  def subscribe(symbol) when is_binary(symbol) do
    GenServer.call(__MODULE__, {:subscribe, symbol, self()})
  end

  @doc """
  Unsubscribe from a symbol's quotes.
  """
  def unsubscribe(symbol) when is_binary(symbol) do
    GenServer.cast(__MODULE__, {:unsubscribe, symbol, self()})
  end

  @doc """
  Get current quote for a symbol (from cache).
  """
  def get_quote(symbol) when is_binary(symbol) do
    GenServer.call(__MODULE__, {:get_quote, symbol})
  end

  @doc """
  Get all currently cached quotes.
  """
  def get_all_quotes do
    GenServer.call(__MODULE__, :get_all_quotes)
  end

  @doc """
  Force an immediate fetch for specific symbols.
  """
  def refresh_symbols(symbols) when is_list(symbols) do
    GenServer.cast(__MODULE__, {:refresh_symbols, symbols})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic fetch
    schedule_fetch()
    schedule_cleanup()

    state = %__MODULE__{
      quotes: %{},
      symbols: MapSet.new(),
      symbol_subscribers: %{},
      last_fetched: %{}
    }

    Logger.info("QuoteCache started")
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, symbol, pid}, _from, state) do
    # Monitor the subscriber so we can clean up when they die
    Process.monitor(pid)

    # Add symbol to watched list
    state = update_in(state.symbols, &MapSet.put(&1, symbol))

    # Add subscriber to symbol's subscriber list
    state = update_in(
      state.symbol_subscribers,
      &Map.update(&1, symbol, MapSet.new([pid]), fn subs -> MapSet.put(subs, pid) end)
    )

    # If we don't have a recent quote, fetch immediately
    should_fetch = case Map.get(state.quotes, symbol) do
      nil -> true
      _ ->
        case Map.get(state.last_fetched, symbol) do
          nil -> true
          timestamp ->
            DateTime.diff(DateTime.utc_now(), timestamp, :millisecond) > @fetch_interval_ms
        end
    end

    if should_fetch do
      send(self(), {:fetch_symbols, [symbol]})
    end

    # Return current quote if available
    quote = Map.get(state.quotes, symbol)
    {:reply, {:ok, quote}, state}
  end

  @impl true
  def handle_call({:get_quote, symbol}, _from, state) do
    quote = Map.get(state.quotes, symbol)
    {:reply, {:ok, quote}, state}
  end

  @impl true
  def handle_call(:get_all_quotes, _from, state) do
    {:reply, {:ok, state.quotes}, state}
  end

  @impl true
  def handle_cast({:unsubscribe, symbol, pid}, state) do
    # Remove subscriber
    state = update_in(
      state.symbol_subscribers,
      fn subs ->
        case Map.get(subs, symbol) do
          nil -> subs
          subscriber_set ->
            new_set = MapSet.delete(subscriber_set, pid)
            if MapSet.size(new_set) == 0 do
              Map.delete(subs, symbol)
            else
              Map.put(subs, symbol, new_set)
            end
        end
      end
    )

    # If no more subscribers, remove symbol from watched list
    state = if !Map.has_key?(state.symbol_subscribers, symbol) do
      update_in(state.symbols, &MapSet.delete(&1, symbol))
    else
      state
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:refresh_symbols, symbols}, state) do
    send(self(), {:fetch_symbols, symbols})
    {:noreply, state}
  end

  @impl true
  def handle_info(:fetch_quotes, state) do
    # Fetch quotes for all watched symbols
    symbols = MapSet.to_list(state.symbols)

    if length(symbols) > 0 do
      send(self(), {:fetch_symbols, symbols})
    end

    # Schedule next fetch
    schedule_fetch()
    {:noreply, state}
  end

  @impl true
  def handle_info({:fetch_symbols, symbols}, state) when is_list(symbols) and length(symbols) > 0 do
    case fetch_market_quotes(symbols) do
      {:ok, new_quotes} ->
        # Update cache
        state = update_in(state.quotes, &Map.merge(&1, new_quotes))

        # Update last fetched timestamps
        now = DateTime.utc_now()
        state = Enum.reduce(Map.keys(new_quotes), state, fn symbol, acc ->
          put_in(acc.last_fetched[symbol], now)
        end)

        # Store quotes in shared ETS for fast concurrent access
        Enum.each(new_quotes, fn {symbol, quote_data} ->
          PriceStore.put_quote(symbol, quote_data)
        end)

        # Broadcast updates via PubSub for each symbol
        Enum.each(new_quotes, fn {symbol, quote_data} ->
          Phoenix.PubSub.broadcast(
            SofiTrader.PubSub,
            "quotes:#{symbol}",
            {:quote_update, symbol, quote_data}
          )
        end)

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Failed to fetch quotes: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:fetch_symbols, []}, state), do: {:noreply, state}

  @impl true
  def handle_info(:cleanup_unused, state) do
    # Remove symbols that haven't been accessed recently and have no subscribers
    now = DateTime.utc_now()

    state = Enum.reduce(state.symbols, state, fn symbol, acc ->
      has_subscribers = Map.has_key?(acc.symbol_subscribers, symbol)

      if !has_subscribers do
        case Map.get(acc.last_fetched, symbol) do
          nil ->
            # Never fetched, remove it
            acc
            |> update_in([:symbols], &MapSet.delete(&1, symbol))
            |> update_in([:quotes], &Map.delete(&1, symbol))
            |> update_in([:last_fetched], &Map.delete(&1, symbol))

          timestamp ->
            age_ms = DateTime.diff(now, timestamp, :millisecond)
            if age_ms > @symbol_ttl_ms do
              Logger.debug("Removing unused symbol from cache: #{symbol}")
              acc
              |> update_in([:symbols], &MapSet.delete(&1, symbol))
              |> update_in([:quotes], &Map.delete(&1, symbol))
              |> update_in([:last_fetched], &Map.delete(&1, symbol))
            else
              acc
            end
        end
      else
        acc
      end
    end)

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Subscriber process died, clean up subscriptions
    state = Enum.reduce(state.symbol_subscribers, state, fn {symbol, subscribers}, acc ->
      if MapSet.member?(subscribers, pid) do
        # Remove this subscriber
        new_subscribers = MapSet.delete(subscribers, pid)

        if MapSet.size(new_subscribers) == 0 do
          # No more subscribers for this symbol
          %{acc |
            symbol_subscribers: Map.delete(acc.symbol_subscribers, symbol),
            symbols: MapSet.delete(acc.symbols, symbol)
          }
        else
          %{acc |
            symbol_subscribers: Map.put(acc.symbol_subscribers, symbol, new_subscribers)
          }
        end
      else
        acc
      end
    end)

    {:noreply, state}
  end

  # Private Functions

  defp fetch_market_quotes(symbols) do
    case MarketData.get_quotes(symbols) do
      {:ok, %{"quotes" => %{"quote" => quotes}}} when is_list(quotes) ->
        quote_map = Map.new(quotes, fn q -> {q["symbol"], q} end)
        {:ok, quote_map}

      {:ok, %{"quotes" => %{"quote" => quote}}} when is_map(quote) ->
        {:ok, %{quote["symbol"] => quote}}

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, _} = error ->
        error
    end
  end

  defp schedule_fetch do
    Process.send_after(self(), :fetch_quotes, @fetch_interval_ms)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_unused, @cleanup_interval_ms)
  end
end
