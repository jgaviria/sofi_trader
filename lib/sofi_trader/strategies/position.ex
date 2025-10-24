defmodule SofiTrader.Strategies.Position do
  @moduledoc """
  Schema for strategy positions.

  Tracks open and closed positions managed by trading strategies, including
  entry/exit prices, P&L, and stop-loss/take-profit levels.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SofiTrader.Strategies.{Strategy, Trade}

  schema "strategy_positions" do
    field :symbol, :string
    field :side, :string
    field :quantity, :integer

    field :entry_price, :decimal
    field :current_price, :decimal
    field :stop_loss_price, :decimal
    field :take_profit_price, :decimal

    field :pnl, :decimal
    field :pnl_percent, :decimal

    field :status, :string, default: "open"
    field :close_reason, :string

    field :opened_at, :utc_datetime
    field :closed_at, :utc_datetime

    belongs_to :strategy, Strategy
    has_many :trades, Trade

    timestamps()
  end

  @doc """
  Changeset for creating a new position.
  """
  def create_changeset(position, attrs) do
    position
    |> cast(attrs, [
      :strategy_id,
      :symbol,
      :side,
      :quantity,
      :entry_price,
      :current_price,
      :stop_loss_price,
      :take_profit_price,
      :opened_at
    ])
    |> validate_required([:strategy_id, :symbol, :side, :quantity, :entry_price])
    |> validate_inclusion(:side, ["buy", "sell"])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:entry_price, greater_than: 0)
    |> foreign_key_constraint(:strategy_id)
    |> put_change(:status, "open")
    |> put_change(:pnl, Decimal.new(0))
    |> put_change(:pnl_percent, Decimal.new(0))
    |> maybe_put_opened_at()
  end

  @doc """
  Changeset for updating position with current price and P&L.
  """
  def update_price_changeset(position, current_price) do
    position
    |> cast(%{current_price: current_price}, [:current_price])
    |> calculate_pnl()
  end

  @doc """
  Changeset for closing a position.
  """
  def close_changeset(position, attrs) do
    position
    |> cast(attrs, [:current_price, :close_reason, :closed_at])
    |> validate_required([:current_price, :close_reason])
    |> validate_inclusion(:close_reason, ["take_profit", "stop_loss", "manual", "strategy_signal"])
    |> put_change(:status, "closed")
    |> calculate_pnl()
    |> maybe_put_closed_at()
  end

  defp calculate_pnl(changeset) do
    entry_price = get_field(changeset, :entry_price)
    current_price = get_field(changeset, :current_price)
    quantity = get_field(changeset, :quantity)
    side = get_field(changeset, :side)

    if entry_price && current_price && quantity do
      {pnl, pnl_pct} = compute_pnl(side, entry_price, current_price, quantity)

      changeset
      |> put_change(:pnl, pnl)
      |> put_change(:pnl_percent, pnl_pct)
    else
      changeset
    end
  end

  defp compute_pnl("buy", entry_price, current_price, quantity) do
    entry = Decimal.new(to_string(entry_price))
    current = Decimal.new(to_string(current_price))
    qty = Decimal.new(quantity)

    pnl = Decimal.mult(Decimal.sub(current, entry), qty)
    pnl_pct = Decimal.mult(Decimal.div(Decimal.sub(current, entry), entry), Decimal.new(100))

    {pnl, pnl_pct}
  end

  defp compute_pnl("sell", entry_price, current_price, quantity) do
    entry = Decimal.new(to_string(entry_price))
    current = Decimal.new(to_string(current_price))
    qty = Decimal.new(quantity)

    pnl = Decimal.mult(Decimal.sub(entry, current), qty)
    pnl_pct = Decimal.mult(Decimal.div(Decimal.sub(entry, current), entry), Decimal.new(100))

    {pnl, pnl_pct}
  end

  defp maybe_put_opened_at(changeset) do
    case get_field(changeset, :opened_at) do
      nil -> put_change(changeset, :opened_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp maybe_put_closed_at(changeset) do
    case get_field(changeset, :closed_at) do
      nil -> put_change(changeset, :closed_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  @doc """
  Checks if stop loss has been hit.
  """
  def stop_loss_hit?(position) do
    if position.stop_loss_price && position.current_price do
      case position.side do
        "buy" ->
          Decimal.compare(
            Decimal.new(to_string(position.current_price)),
            Decimal.new(to_string(position.stop_loss_price))
          ) != :gt

        "sell" ->
          Decimal.compare(
            Decimal.new(to_string(position.current_price)),
            Decimal.new(to_string(position.stop_loss_price))
          ) != :lt
      end
    else
      false
    end
  end

  @doc """
  Checks if take profit has been hit.
  """
  def take_profit_hit?(position) do
    if position.take_profit_price && position.current_price do
      case position.side do
        "buy" ->
          Decimal.compare(
            Decimal.new(to_string(position.current_price)),
            Decimal.new(to_string(position.take_profit_price))
          ) != :lt

        "sell" ->
          Decimal.compare(
            Decimal.new(to_string(position.current_price)),
            Decimal.new(to_string(position.take_profit_price))
          ) != :gt
      end
    else
      false
    end
  end
end
