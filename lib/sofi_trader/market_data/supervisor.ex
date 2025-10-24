defmodule SofiTrader.MarketData.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing market data candle aggregators.

  Ensures each symbol/timeframe combination has at most one aggregator running.
  """
  use DynamicSupervisor
  require Logger

  alias SofiTrader.MarketData.CandleAggregator

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a candle aggregator for the given symbol and timeframe.
  Returns {:ok, pid} if started successfully, or {:error, reason} if already running.
  """
  def start_aggregator(symbol, timeframe_minutes) do
    # Check if already running
    case Registry.lookup(SofiTrader.MarketDataRegistry, {symbol, timeframe_minutes}) do
      [{_pid, _}] ->
        Logger.debug("Candle aggregator already running for #{symbol} (#{timeframe_minutes}min)")
        {:ok, :already_started}

      [] ->
        child_spec = %{
          id: {CandleAggregator, {symbol, timeframe_minutes}},
          start: {CandleAggregator, :start_link, [[symbol: symbol, timeframe_minutes: timeframe_minutes]]},
          restart: :transient
        }

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} ->
            Logger.info("Started candle aggregator for #{symbol} (#{timeframe_minutes}min)")
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, reason} = error ->
            Logger.error("Failed to start candle aggregator for #{symbol}: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Stops the candle aggregator for the given symbol and timeframe.
  """
  def stop_aggregator(symbol, timeframe_minutes) do
    case Registry.lookup(SofiTrader.MarketDataRegistry, {symbol, timeframe_minutes}) do
      [{pid, _}] ->
        Logger.info("Stopping candle aggregator for #{symbol} (#{timeframe_minutes}min)")
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns list of all running aggregators.
  """
  def list_aggregators do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  @doc """
  Checks if there are any active strategies for this symbol/timeframe combination.
  If not, stops the aggregator.
  """
  def maybe_stop_unused_aggregator(symbol, timeframe_minutes) do
    alias SofiTrader.Strategies

    # Check if any active strategies use this symbol/timeframe
    active_strategies =
      Strategies.list_strategies()
      |> Enum.filter(fn s ->
        s.status == "active" &&
          s.symbol == symbol &&
          parse_timeframe(s.config["timeframe"]) == timeframe_minutes
      end)

    if Enum.empty?(active_strategies) do
      Logger.info("No active strategies for #{symbol} (#{timeframe_minutes}min), stopping aggregator")
      stop_aggregator(symbol, timeframe_minutes)
    else
      Logger.debug("#{length(active_strategies)} active strategies for #{symbol} (#{timeframe_minutes}min)")
      :ok
    end
  end

  defp parse_timeframe(timeframe) do
    case timeframe do
      "1min" -> 1
      "5min" -> 5
      "15min" -> 15
      "30min" -> 30
      "1hour" -> 60
      "4hour" -> 240
      "1day" -> 1440
      _ -> 5 # default
    end
  end
end
