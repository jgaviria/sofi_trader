defmodule SofiTrader.Kalshi.Strategies do
  @moduledoc """
  Context module for Kalshi strategy management.

  Provides functions for CRUD operations on strategies, positions, orders, and alerts.
  """

  import Ecto.Query
  alias SofiTrader.Repo
  alias SofiTrader.Kalshi.{Strategy, Position, Order, Alert}

  # ============================================================================
  # Strategies
  # ============================================================================

  @doc """
  List all Kalshi strategies.
  """
  def list_strategies do
    Strategy
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
  end

  @doc """
  List active strategies (status = "active").
  """
  def list_active_strategies do
    Strategy
    |> where([s], s.status == "active")
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  @doc """
  Get a strategy by ID.
  """
  def get_strategy(id), do: Repo.get(Strategy, id)

  @doc """
  Get a strategy by ID with preloaded associations.
  """
  def get_strategy_with_details(id) do
    Strategy
    |> where([s], s.id == ^id)
    |> preload([:positions, :orders, :alerts])
    |> Repo.one()
  end

  @doc """
  Create a new strategy.
  """
  def create_strategy(attrs \\ %{}) do
    %Strategy{}
    |> Strategy.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a strategy.
  """
  def update_strategy(%Strategy{} = strategy, attrs) do
    strategy
    |> Strategy.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a strategy.
  """
  def delete_strategy(%Strategy{} = strategy) do
    Repo.delete(strategy)
  end

  @doc """
  Change strategy status.
  """
  def update_status(%Strategy{} = strategy, status) when status in ["active", "paused", "stopped"] do
    update_strategy(strategy, %{status: status})
  end

  @doc """
  Get strategy changeset for forms.
  """
  def change_strategy(%Strategy{} = strategy, attrs \\ %{}) do
    Strategy.changeset(strategy, attrs)
  end

  # ============================================================================
  # Positions
  # ============================================================================

  @doc """
  List all positions for a strategy.
  """
  def list_positions(strategy_id) do
    Position
    |> where([p], p.strategy_id == ^strategy_id)
    |> order_by([p], desc: p.opened_at)
    |> Repo.all()
  end

  @doc """
  List open positions for a strategy.
  """
  def list_open_positions(strategy_id) do
    Position
    |> where([p], p.strategy_id == ^strategy_id and p.status == "open")
    |> Repo.all()
  end

  @doc """
  Get position by market ticker for a strategy.
  """
  def get_position_by_ticker(strategy_id, market_ticker) do
    Position
    |> where([p], p.strategy_id == ^strategy_id and p.market_ticker == ^market_ticker and p.status == "open")
    |> Repo.one()
  end

  @doc """
  Create a new position.
  """
  def create_position(attrs) do
    %Position{}
    |> Position.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a position.
  """
  def update_position(%Position{} = position, attrs) do
    position
    |> Position.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Update position with current market price and recalculate P&L.
  """
  def update_position_price(%Position{} = position, current_price_cents) do
    unrealized_pnl = (current_price_cents - position.avg_price_cents) * position.contracts
    current_value = current_price_cents * position.contracts

    update_position(position, %{
      current_price_cents: current_price_cents,
      current_value_cents: current_value,
      unrealized_pnl_cents: unrealized_pnl
    })
  end

  @doc """
  Close a position.
  """
  def close_position(%Position{} = position, realized_pnl_cents) do
    update_position(position, %{
      status: "closed",
      realized_pnl_cents: realized_pnl_cents,
      closed_at: DateTime.utc_now()
    })
  end

  # ============================================================================
  # Orders
  # ============================================================================

  @doc """
  List all orders for a strategy.
  """
  def list_orders(strategy_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Order
    |> where([o], o.strategy_id == ^strategy_id)
    |> order_by([o], desc: o.placed_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  List active (resting) orders for a strategy.
  """
  def list_active_orders(strategy_id) do
    Order
    |> where([o], o.strategy_id == ^strategy_id and o.status in ["pending", "resting"])
    |> Repo.all()
  end

  @doc """
  Get order by Kalshi order ID.
  """
  def get_order_by_kalshi_id(order_id) do
    Order
    |> where([o], o.order_id == ^order_id)
    |> Repo.one()
  end

  @doc """
  Create a new order record.
  """
  def create_order(attrs) do
    %Order{}
    |> Order.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update an order (e.g., when filled or canceled).
  """
  def update_order(%Order{} = order, attrs) do
    order
    |> Order.update_changeset(attrs)
    |> Repo.update()
  end

  # ============================================================================
  # Alerts
  # ============================================================================

  @doc """
  List alerts for a strategy.
  """
  def list_alerts(strategy_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    unacknowledged_only = Keyword.get(opts, :unacknowledged_only, false)

    query = Alert
    |> where([a], a.strategy_id == ^strategy_id)
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)

    query = if unacknowledged_only do
      where(query, [a], a.acknowledged == false)
    else
      query
    end

    Repo.all(query)
  end

  @doc """
  List recent alerts across all strategies.
  """
  def list_recent_alerts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Alert
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> preload(:strategy)
    |> Repo.all()
  end

  @doc """
  Create an alert.
  """
  def create_alert(attrs) do
    %Alert{}
    |> Alert.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Acknowledge an alert.
  """
  def acknowledge_alert(%Alert{} = alert) do
    alert
    |> Alert.acknowledge_changeset()
    |> Repo.update()
  end

  @doc """
  Acknowledge all alerts for a strategy.
  """
  def acknowledge_all_alerts(strategy_id) do
    Alert
    |> where([a], a.strategy_id == ^strategy_id and a.acknowledged == false)
    |> Repo.update_all(set: [acknowledged: true, acknowledged_at: DateTime.utc_now()])
  end

  # ============================================================================
  # Statistics
  # ============================================================================

  @doc """
  Update strategy statistics after a trade.
  """
  def update_strategy_stats(%Strategy{} = strategy) do
    orders = list_orders(strategy.id)
    positions = list_positions(strategy.id)
    alerts = list_alerts(strategy.id)

    filled_orders = Enum.filter(orders, &(&1.status == "executed"))
    total_contracts = Enum.reduce(filled_orders, 0, &(&1.filled_count + &2))
    realized_pnl = Enum.reduce(positions, 0, &(&1.realized_pnl_cents + &2))

    stats = %{
      "total_alerts" => length(alerts),
      "total_orders" => length(orders),
      "filled_orders" => length(filled_orders),
      "total_contracts_traded" => total_contracts,
      "realized_pnl_cents" => realized_pnl,
      "last_updated" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    update_strategy(strategy, %{stats: stats})
  end

  @doc """
  Calculate total exposure across all active strategies.
  """
  def total_exposure do
    Position
    |> where([p], p.status == "open")
    |> select([p], sum(p.current_value_cents))
    |> Repo.one() || 0
  end

  @doc """
  Calculate today's P&L across all strategies.
  """
  def todays_pnl do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    Position
    |> where([p], p.closed_at >= ^start_of_day)
    |> select([p], sum(p.realized_pnl_cents))
    |> Repo.one() || 0
  end
end
