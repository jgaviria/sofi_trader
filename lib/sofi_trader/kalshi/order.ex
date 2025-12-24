defmodule SofiTrader.Kalshi.Order do
  @moduledoc """
  Schema for Kalshi orders.

  Tracks all orders placed through strategies, including:
  - Order details (side, action, price, count)
  - Fill status and execution details
  - Link to strategy and position
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SofiTrader.Kalshi.{Strategy, Position}

  @type t :: %__MODULE__{}

  @sides ["yes", "no"]
  @actions ["buy", "sell"]
  @types ["limit", "market"]
  @statuses ["pending", "resting", "executed", "canceled", "partial"]
  @time_in_forces ["gtc", "ioc", "fok"]

  schema "kalshi_orders" do
    field :order_id, :string
    field :client_order_id, :string
    field :market_ticker, :string
    field :side, :string
    field :action, :string
    field :type, :string
    field :count, :integer
    field :filled_count, :integer, default: 0
    field :remaining_count, :integer
    field :price_cents, :integer
    field :avg_fill_price_cents, :integer
    field :status, :string
    field :time_in_force, :string
    field :fees_cents, :integer, default: 0
    field :placed_at, :utc_datetime
    field :filled_at, :utc_datetime
    field :canceled_at, :utc_datetime

    belongs_to :strategy, Strategy
    belongs_to :position, Position

    timestamps()
  end

  @doc """
  Changeset for creating a new order.
  """
  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :strategy_id, :position_id, :order_id, :client_order_id, :market_ticker,
      :side, :action, :type, :count, :filled_count, :remaining_count,
      :price_cents, :avg_fill_price_cents, :status, :time_in_force,
      :fees_cents, :placed_at, :filled_at, :canceled_at
    ])
    |> validate_required([:order_id, :market_ticker, :side, :action, :type, :count])
    |> validate_inclusion(:side, @sides)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:time_in_force, @time_in_forces)
    |> validate_number(:count, greater_than: 0)
    |> validate_number(:price_cents, greater_than: 0, less_than: 100)
    |> foreign_key_constraint(:strategy_id)
    |> foreign_key_constraint(:position_id)
    |> unique_constraint(:order_id)
  end

  @doc """
  Update changeset for order status changes.
  """
  def update_changeset(order, attrs) do
    order
    |> cast(attrs, [
      :filled_count, :remaining_count, :avg_fill_price_cents,
      :status, :fees_cents, :filled_at, :canceled_at
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Check if order is fully filled.
  """
  def filled?(%__MODULE__{filled_count: filled, count: count})
      when filled == count, do: true
  def filled?(_), do: false

  @doc """
  Check if order is still active (can be filled or canceled).
  """
  def active?(%__MODULE__{status: status})
      when status in ["pending", "resting"], do: true
  def active?(_), do: false

  @doc """
  Calculate the total cost/proceeds of the order.

  For buy orders: cost = filled_count * avg_fill_price
  For sell orders: proceeds = filled_count * avg_fill_price
  """
  def total_value(%__MODULE__{filled_count: filled, avg_fill_price_cents: price})
      when is_integer(filled) and is_integer(price) do
    filled * price
  end

  def total_value(_), do: 0

  @doc """
  Generate a client order ID for tracking.
  """
  def generate_client_order_id(strategy_id) do
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "strat_#{strategy_id}_#{timestamp}_#{random}"
  end
end
