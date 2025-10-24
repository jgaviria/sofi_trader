defmodule SofiTrader.Strategies.Trade do
  @moduledoc """
  Schema for strategy trades.

  Records individual order executions for strategies, including entry and exit trades,
  with associated fees and P&L calculations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SofiTrader.Strategies.{Strategy, Position}

  schema "strategy_trades" do
    field :order_id, :string
    field :symbol, :string
    field :side, :string
    field :quantity, :integer
    field :price, :decimal
    field :fees, :decimal
    field :pnl, :decimal
    field :pnl_percent, :decimal
    field :executed_at, :utc_datetime

    belongs_to :strategy, Strategy
    belongs_to :position, Position

    timestamps()
  end

  @doc """
  Changeset for creating a new trade.
  """
  def changeset(trade, attrs) do
    trade
    |> cast(attrs, [
      :strategy_id,
      :position_id,
      :order_id,
      :symbol,
      :side,
      :quantity,
      :price,
      :fees,
      :pnl,
      :pnl_percent,
      :executed_at
    ])
    |> validate_required([:strategy_id, :symbol, :side, :quantity, :price])
    |> validate_inclusion(:side, ["buy", "sell"])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:price, greater_than: 0)
    |> foreign_key_constraint(:strategy_id)
    |> foreign_key_constraint(:position_id)
    |> maybe_put_executed_at()
  end

  defp maybe_put_executed_at(changeset) do
    case get_field(changeset, :executed_at) do
      nil -> put_change(changeset, :executed_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  @doc """
  Calculates the trade value (price * quantity).
  """
  def trade_value(trade) do
    price = Decimal.new(to_string(trade.price))
    quantity = Decimal.new(trade.quantity)
    Decimal.mult(price, quantity)
  end

  @doc """
  Calculates the total cost including fees.
  """
  def total_cost(trade) do
    value = trade_value(trade)
    fees = if trade.fees, do: Decimal.new(to_string(trade.fees)), else: Decimal.new(0)
    Decimal.add(value, fees)
  end
end
