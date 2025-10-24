defmodule SofiTrader.MarketData.PriceStore do
  @moduledoc """
  ETS-based high-performance storage for market data.

  Provides blazing-fast, concurrent read access to:
  - Recent price history per symbol
  - Latest candles per symbol/timeframe
  - Latest quotes per symbol

  Uses ETS for lock-free concurrent reads across all processes.
  """
  use GenServer
  require Logger

  @table_name :market_data_store
  @price_history_limit 200  # Keep last 200 prices per symbol
  @candle_history_limit 100  # Keep last 100 candles per symbol/timeframe

  defstruct [:table]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store price history for a symbol.
  Automatically limits to most recent prices.
  """
  def put_price_history(symbol, prices) when is_list(prices) do
    limited_prices = Enum.take(prices, @price_history_limit)
    :ets.insert(@table_name, {{:price_history, symbol}, limited_prices, DateTime.utc_now()})
    :ok
  end

  @doc """
  Get price history for a symbol.
  Returns list of prices (most recent first) or empty list if not found.
  """
  def get_price_history(symbol) do
    case :ets.lookup(@table_name, {:price_history, symbol}) do
      [{{:price_history, ^symbol}, prices, _timestamp}] -> prices
      [] -> []
    end
  end

  @doc """
  Add a single price to symbol's history.
  Maintains the price limit automatically.
  """
  def add_price(symbol, price) when is_number(price) do
    current_history = get_price_history(symbol)
    new_history = [price | current_history] |> Enum.take(@price_history_limit)
    put_price_history(symbol, new_history)
  end

  @doc """
  Store a candle for a symbol/timeframe.
  """
  def put_candle(symbol, timeframe, candle) do
    key = {:candle, symbol, timeframe}

    # Get existing candles
    candles = case :ets.lookup(@table_name, key) do
      [{^key, existing_candles, _}] -> existing_candles
      [] -> []
    end

    # Add new candle and limit
    new_candles = [candle | candles] |> Enum.take(@candle_history_limit)

    :ets.insert(@table_name, {key, new_candles, DateTime.utc_now()})
    :ok
  end

  @doc """
  Get candle history for a symbol/timeframe.
  Returns list of candles (most recent first).
  """
  def get_candles(symbol, timeframe) do
    case :ets.lookup(@table_name, {:candle, symbol, timeframe}) do
      [{{:candle, ^symbol, ^timeframe}, candles, _timestamp}] -> candles
      [] -> []
    end
  end

  @doc """
  Get the latest candle for a symbol/timeframe.
  """
  def get_latest_candle(symbol, timeframe) do
    case get_candles(symbol, timeframe) do
      [latest | _] -> {:ok, latest}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Store latest quote for a symbol.
  """
  def put_quote(symbol, quote) do
    :ets.insert(@table_name, {{:quote, symbol}, quote, DateTime.utc_now()})
    :ok
  end

  @doc """
  Get latest quote for a symbol.
  """
  def get_quote(symbol) do
    case :ets.lookup(@table_name, {:quote, symbol}) do
      [{{:quote, ^symbol}, quote, _timestamp}] -> {:ok, quote}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Get all stored symbols.
  """
  def list_symbols do
    :ets.match(@table_name, {{:price_history, :"$1"}, :_, :_})
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Clear all data for a symbol.
  """
  def clear_symbol(symbol) do
    # Delete all entries related to this symbol
    :ets.match_delete(@table_name, {{:price_history, symbol}, :_, :_})
    :ets.match_delete(@table_name, {{:quote, symbol}, :_, :_})

    # Delete candles for all timeframes
    :ets.match_delete(@table_name, {{:candle, symbol, :_}, :_, :_})
    :ok
  end

  @doc """
  Get ETS table info and statistics.
  """
  def info do
    %{
      size: :ets.info(@table_name, :size),
      memory: :ets.info(@table_name, :memory),
      type: :ets.info(@table_name, :type),
      read_concurrency: :ets.info(@table_name, :read_concurrency),
      write_concurrency: :ets.info(@table_name, :write_concurrency)
    }
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table with optimal settings for concurrent reads
    table = :ets.new(@table_name, [
      :set,                    # Key-value store
      :named_table,            # Access by name
      :public,                 # All processes can read/write
      read_concurrency: true,  # Optimize for concurrent reads
      write_concurrency: true  # Allow concurrent writes
    ])

    Logger.info("PriceStore ETS table created: #{inspect(@table_name)}")

    state = %__MODULE__{table: table}
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup_old_data, state) do
    # Periodically clean up very old data
    # This could be expanded to remove stale entries
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # ETS table will be automatically deleted when process dies
    Logger.info("PriceStore terminating, ETS table will be cleaned up")
    {:ok, state}
  end
end
