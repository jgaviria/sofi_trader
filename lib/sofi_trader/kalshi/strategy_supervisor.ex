defmodule SofiTrader.Kalshi.StrategySupervisor do
  @moduledoc """
  Supervisor for Kalshi strategy runner processes.

  Manages all active Kalshi strategy runners and ensures they are restarted on failure.
  Each strategy runs in its own supervised GenServer process.
  """

  use DynamicSupervisor
  require Logger

  alias SofiTrader.Kalshi.{Strategies, StrategyRunner, WebSocketManager}

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a strategy runner for the given Kalshi strategy.

  ## Options
    - `:paper_trading` - If true, simulates trades (default: true for safety)
  """
  def start_strategy(strategy_id, opts \\ []) do
    paper_trading = Keyword.get(opts, :paper_trading, true)

    strategy = Strategies.get_strategy(strategy_id)

    unless strategy do
      {:error, :strategy_not_found}
    else
      # Ensure WebSocket connection is active
      ensure_websocket_connection()

      child_spec = %{
        id: {StrategyRunner, strategy_id},
        start: {StrategyRunner, :start_link, [[strategy_id: strategy_id, paper_trading: paper_trading]]},
        restart: :transient
      }

      case DynamicSupervisor.start_child(__MODULE__, child_spec) do
        {:ok, pid} ->
          Logger.info("[Kalshi Supervisor] Started strategy #{strategy.name} (ID: #{strategy_id})")

          # Update strategy status
          Strategies.update_status(strategy, "active")

          {:ok, pid}

        {:error, {:already_started, pid}} ->
          Logger.warning("[Kalshi Supervisor] Strategy #{strategy_id} already running")
          {:ok, pid}

        {:error, reason} ->
          Logger.error("[Kalshi Supervisor] Failed to start strategy #{strategy_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Stops a running strategy.
  """
  def stop_strategy(strategy_id) do
    case Registry.lookup(SofiTrader.KalshiStrategyRegistry, strategy_id) do
      [{pid, _}] ->
        Logger.info("[Kalshi Supervisor] Stopping strategy #{strategy_id}")

        # Update strategy status
        if strategy = Strategies.get_strategy(strategy_id) do
          Strategies.update_status(strategy, "stopped")
        end

        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_running}
    end
  end

  @doc """
  Pause a running strategy (stops runner but marks as paused).
  """
  def pause_strategy(strategy_id) do
    case stop_strategy(strategy_id) do
      :ok ->
        if strategy = Strategies.get_strategy(strategy_id) do
          Strategies.update_status(strategy, "paused")
        end
        :ok

      error ->
        error
    end
  end

  @doc """
  Returns a list of all running strategy PIDs.
  """
  def list_running do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&Process.alive?/1)
  end

  @doc """
  Returns running strategies with their IDs.
  """
  def list_running_with_ids do
    Registry.select(SofiTrader.KalshiStrategyRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Starts all active strategies from the database.

  Called on application startup to resume running strategies.
  """
  def start_all_active(opts \\ []) do
    paper_trading = Keyword.get(opts, :paper_trading, true)

    active_strategies = Strategies.list_active_strategies()

    if length(active_strategies) > 0 do
      Logger.info("[Kalshi Supervisor] Starting #{length(active_strategies)} active strategies")

      Enum.each(active_strategies, fn strategy ->
        Logger.info("[Kalshi Supervisor] Auto-starting: #{strategy.name}")
        start_strategy(strategy.id, paper_trading: paper_trading)
      end)
    end
  end

  @doc """
  Stops all running strategies.
  """
  def stop_all do
    list_running_with_ids()
    |> Enum.each(fn {strategy_id, _pid} ->
      stop_strategy(strategy_id)
    end)
  end

  @doc """
  Check if a strategy is currently running.
  """
  def running?(strategy_id) do
    StrategyRunner.running?(strategy_id)
  end

  @doc """
  Get the current state of a running strategy.
  """
  def get_strategy_state(strategy_id) do
    if running?(strategy_id) do
      StrategyRunner.get_state(strategy_id)
    else
      {:error, :not_running}
    end
  end

  # Private helpers

  defp ensure_websocket_connection do
    # Check if WebSocket manager is running and configured
    if WebSocketManager.configured?() do
      case Process.whereis(WebSocketManager) do
        nil ->
          Logger.warning("[Kalshi Supervisor] WebSocket manager not running")

        pid when is_pid(pid) ->
          status = WebSocketManager.status()
          unless status.connected do
            Logger.warning("[Kalshi Supervisor] WebSocket not connected")
          end
      end
    end
  end
end
