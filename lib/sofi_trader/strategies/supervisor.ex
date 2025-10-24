defmodule SofiTrader.Strategies.Supervisor do
  @moduledoc """
  Supervisor for strategy runner processes.

  Manages all active strategy runners and ensures they are restarted on failure.
  Each strategy runs in its own supervised GenServer process.
  """

  use DynamicSupervisor
  require Logger

  alias SofiTrader.Strategies
  alias SofiTrader.Strategies.Runner

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a strategy runner for the given strategy.

  ## Options

    - strategy_id: The ID of the strategy to run
    - paper_trading: If true, simulates trades (default: false)
  """
  def start_strategy(strategy_id, opts \\ []) do
    paper_trading = Keyword.get(opts, :paper_trading, false)

    child_spec = %{
      id: {Runner, strategy_id},
      start: {Runner, :start_link, [[strategy_id: strategy_id, paper_trading: paper_trading]]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Started strategy runner for strategy #{strategy_id} (PID: #{inspect(pid)})")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.warning("Strategy #{strategy_id} is already running (PID: #{inspect(pid)})")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start strategy #{strategy_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stops a running strategy.
  """
  def stop_strategy(strategy_id) do
    case Registry.lookup(SofiTrader.StrategyRegistry, strategy_id) do
      [{pid, _}] ->
        Logger.info("Stopping strategy runner for strategy #{strategy_id}")
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_running}
    end
  end

  @doc """
  Returns a list of all running strategies.
  """
  def list_running_strategies do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&Process.alive?/1)
  end

  @doc """
  Starts all active strategies from the database.

  Called on application startup to resume running strategies.
  """
  def start_all_active_strategies(opts \\ []) do
    paper_trading = Keyword.get(opts, :paper_trading, false)

    Strategies.list_active_strategies()
    |> Enum.each(fn strategy ->
      Logger.info("Auto-starting strategy: #{strategy.name} (#{strategy.symbol})")
      start_strategy(strategy.id, paper_trading: paper_trading)
    end)
  end

  @doc """
  Stops all running strategies.
  """
  def stop_all_strategies do
    list_running_strategies()
    |> Enum.each(fn pid ->
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end)
  end

  @doc """
  Checks if a strategy is currently running.
  """
  def strategy_running?(strategy_id) do
    case Registry.lookup(SofiTrader.StrategyRegistry, strategy_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end
end
