defmodule SofiTrader.Strategies do
  @moduledoc """
  The Strategies context.

  Provides functions for managing trading strategies, positions, and trades.
  """

  import Ecto.Query, warn: false
  alias SofiTrader.Repo

  alias SofiTrader.Strategies.{Strategy, Position, Trade}

  ## Strategies

  @doc """
  Returns the list of strategies.
  """
  def list_strategies do
    Repo.all(Strategy)
  end

  @doc """
  Returns the list of active strategies.
  """
  def list_active_strategies do
    Repo.all(from s in Strategy, where: s.status == "active")
  end

  @doc """
  Gets a single strategy.

  Raises `Ecto.NoResultsError` if the Strategy does not exist.
  """
  def get_strategy!(id) do
    Repo.get!(Strategy, id)
  end

  @doc """
  Gets a single strategy with preloaded associations.
  """
  def get_strategy_with_positions!(id) do
    Strategy
    |> Repo.get!(id)
    |> Repo.preload([:positions, :trades])
  end

  @doc """
  Creates a strategy.
  """
  def create_strategy(attrs \\ %{}) do
    %Strategy{}
    |> Strategy.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a strategy.
  """
  def update_strategy(%Strategy{} = strategy, attrs) do
    strategy
    |> Strategy.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a strategy.
  """
  def delete_strategy(%Strategy{} = strategy) do
    Repo.delete(strategy)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking strategy changes.
  """
  def change_strategy(%Strategy{} = strategy, attrs \\ %{}) do
    Strategy.changeset(strategy, attrs)
  end

  @doc """
  Starts a strategy (sets status to active).
  """
  def start_strategy(%Strategy{} = strategy) do
    stats = strategy.stats || Strategy.initial_stats()
    started_at = stats["started_at"] || DateTime.to_iso8601(DateTime.utc_now())

    strategy
    |> update_strategy(%{
      status: "active",
      stats: Map.put(stats, "started_at", started_at)
    })
  end

  @doc """
  Stops a strategy (sets status to stopped).
  """
  def stop_strategy(%Strategy{} = strategy) do
    update_strategy(strategy, %{status: "stopped"})
  end

  @doc """
  Pauses a strategy (sets status to paused).
  """
  def pause_strategy(%Strategy{} = strategy) do
    update_strategy(strategy, %{status: "paused"})
  end

  @doc """
  Updates strategy statistics after a trade.
  """
  def update_strategy_stats(%Strategy{} = strategy, trade_pnl) do
    stats = strategy.stats || Strategy.initial_stats()

    total_trades = (stats["total_trades"] || 0) + 1
    winning_trades = if trade_pnl > 0, do: (stats["winning_trades"] || 0) + 1, else: stats["winning_trades"] || 0
    losing_trades = if trade_pnl < 0, do: (stats["losing_trades"] || 0) + 1, else: stats["losing_trades"] || 0
    win_rate = if total_trades > 0, do: winning_trades / total_trades * 100, else: 0.0

    total_pnl = (stats["total_pnl"] || 0.0) + trade_pnl
    largest_win = max(stats["largest_win"] || 0.0, trade_pnl)
    largest_loss = min(stats["largest_loss"] || 0.0, trade_pnl)

    current_streak =
      cond do
        trade_pnl > 0 and (stats["current_streak"] || 0) >= 0 ->
          (stats["current_streak"] || 0) + 1

        trade_pnl < 0 and (stats["current_streak"] || 0) <= 0 ->
          (stats["current_streak"] || 0) - 1

        trade_pnl > 0 ->
          1

        true ->
          -1
      end

    new_stats = %{
      "total_trades" => total_trades,
      "winning_trades" => winning_trades,
      "losing_trades" => losing_trades,
      "win_rate" => Float.round(win_rate, 2),
      "total_pnl" => Float.round(total_pnl, 2),
      "largest_win" => Float.round(largest_win, 2),
      "largest_loss" => Float.round(largest_loss, 2),
      "current_streak" => current_streak,
      "started_at" => stats["started_at"],
      "last_trade_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    update_strategy(strategy, %{stats: new_stats})
  end

  ## Positions

  @doc """
  Returns the list of positions for a strategy.
  """
  def list_positions(strategy_id) do
    Repo.all(from p in Position, where: p.strategy_id == ^strategy_id, order_by: [desc: p.opened_at])
  end

  @doc """
  Returns the list of open positions for a strategy.
  """
  def list_open_positions(strategy_id) do
    Repo.all(
      from p in Position,
        where: p.strategy_id == ^strategy_id and p.status == "open",
        order_by: [desc: p.opened_at]
    )
  end

  @doc """
  Gets a single position.
  """
  def get_position!(id) do
    Repo.get!(Position, id)
  end

  @doc """
  Creates a position.
  """
  def create_position(attrs \\ %{}) do
    %Position{}
    |> Position.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a position with current price.
  """
  def update_position_price(%Position{} = position, current_price) do
    position
    |> Position.update_price_changeset(current_price)
    |> Repo.update()
  end

  @doc """
  Closes a position.
  """
  def close_position(%Position{} = position, current_price, reason) do
    position
    |> Position.close_changeset(%{
      current_price: current_price,
      close_reason: reason
    })
    |> Repo.update()
  end

  ## Trades

  @doc """
  Returns the list of trades for a strategy.
  """
  def list_trades(strategy_id, limit \\ 50) do
    Repo.all(
      from t in Trade,
        where: t.strategy_id == ^strategy_id,
        order_by: [desc: t.executed_at],
        limit: ^limit
    )
  end

  @doc """
  Creates a trade.
  """
  def create_trade(attrs \\ %{}) do
    %Trade{}
    |> Trade.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets trades for a position.
  """
  def get_position_trades(position_id) do
    Repo.all(from t in Trade, where: t.position_id == ^position_id, order_by: [asc: t.executed_at])
  end
end
