defmodule SofiTrader.Kalshi.Position do
  @moduledoc """
  Schema for Kalshi market positions.

  Tracks the user's position in a specific market, including:
  - Side (YES or NO contracts)
  - Number of contracts
  - Average entry price
  - Current value and P&L
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SofiTrader.Kalshi.{Strategy, Order}

  @type t :: %__MODULE__{}

  @sides ["yes", "no"]
  @statuses ["open", "closed", "settled"]

  schema "kalshi_positions" do
    field :market_ticker, :string
    field :side, :string
    field :contracts, :integer
    field :avg_price_cents, :integer
    field :current_price_cents, :integer
    field :current_value_cents, :integer
    field :realized_pnl_cents, :integer, default: 0
    field :unrealized_pnl_cents, :integer, default: 0
    field :status, :string, default: "open"
    field :settlement_value, :integer
    field :opened_at, :utc_datetime
    field :closed_at, :utc_datetime

    belongs_to :strategy, Strategy
    has_many :orders, Order

    timestamps()
  end

  @doc """
  Changeset for creating or updating a position.
  """
  def changeset(position, attrs) do
    position
    |> cast(attrs, [
      :strategy_id, :market_ticker, :side, :contracts, :avg_price_cents,
      :current_price_cents, :current_value_cents, :realized_pnl_cents,
      :unrealized_pnl_cents, :status, :settlement_value, :opened_at, :closed_at
    ])
    |> validate_required([:market_ticker, :side, :contracts])
    |> validate_inclusion(:side, @sides)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:contracts, greater_than: 0)
    |> validate_number(:avg_price_cents, greater_than: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:strategy_id)
  end

  @doc """
  Calculate the current value of the position.

  For YES contracts: value = contracts * current_yes_price
  For NO contracts: value = contracts * (100 - current_yes_price)
  """
  def calculate_value(%__MODULE__{contracts: contracts, current_price_cents: price})
      when is_integer(price) do
    contracts * price
  end

  def calculate_value(_), do: 0

  @doc """
  Calculate unrealized P&L.

  P&L = (current_price - avg_entry_price) * contracts
  For short positions, this is inverted.
  """
  def calculate_unrealized_pnl(%__MODULE__{
        contracts: contracts,
        avg_price_cents: avg_price,
        current_price_cents: current_price
      })
      when is_integer(avg_price) and is_integer(current_price) do
    (current_price - avg_price) * contracts
  end

  def calculate_unrealized_pnl(_), do: 0

  @doc """
  Calculate the max profit and max loss for the position.

  For YES contracts bought at X cents:
  - Max profit: (100 - X) * contracts (if event happens)
  - Max loss: X * contracts (if event doesn't happen)
  """
  def calculate_risk(%__MODULE__{side: "yes", contracts: contracts, avg_price_cents: price})
      when is_integer(price) do
    %{
      max_profit_cents: (100 - price) * contracts,
      max_loss_cents: price * contracts
    }
  end

  def calculate_risk(%__MODULE__{side: "no", contracts: contracts, avg_price_cents: price})
      when is_integer(price) do
    %{
      max_profit_cents: (100 - price) * contracts,
      max_loss_cents: price * contracts
    }
  end

  def calculate_risk(_), do: %{max_profit_cents: 0, max_loss_cents: 0}

  @doc """
  Check if position should be marked as settled.
  """
  def settled?(%__MODULE__{status: "settled"}), do: true
  def settled?(_), do: false
end
