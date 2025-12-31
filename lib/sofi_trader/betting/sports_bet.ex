defmodule SofiTrader.Betting.SportsBet do
  @moduledoc """
  Schema for tracking sports bets with AI analysis and outcomes.

  Each bet records:
  - The market and bet details (ticker, side, price, contracts)
  - AI recommendation at time of bet (if AI-driven)
  - Outcome (won, lost, pending)
  - Profit/loss statistics
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending won lost push sold canceled)

  schema "sports_bets" do
    # Kalshi identifiers
    field :kalshi_fill_id, :string
    field :kalshi_order_id, :string
    field :market_ticker, :string
    field :event_ticker, :string

    # Market info at time of bet
    field :market_title, :string
    field :team_a, :string
    field :team_b, :string
    field :sport, :string

    # Bet details
    field :side, :string           # "yes" or "no"
    field :action, :string         # "buy" or "sell"
    field :contracts, :integer
    field :price_cents, :integer
    field :cost_cents, :integer
    field :fees_cents, :integer, default: 0

    # AI analysis at time of bet
    field :ai_recommendation, :string
    field :ai_confidence, :decimal
    field :ai_fair_value, :integer
    field :ai_edge, :integer
    field :ai_reasoning, :string
    field :ai_key_factors, {:array, :string}
    field :ai_model, :string

    # Web context
    field :web_context_summary, :string

    # Outcome tracking
    field :status, :string, default: "pending"
    field :settlement_value, :integer
    field :payout_cents, :integer
    field :profit_cents, :integer
    field :roi_percent, :decimal

    # Close tracking
    field :close_price_cents, :integer
    field :close_payout_cents, :integer

    # Timestamps
    field :placed_at, :utc_datetime
    field :game_date, :date
    field :settled_at, :utc_datetime
    field :synced_at, :utc_datetime

    timestamps()
  end

  @required_fields ~w(market_ticker side action contracts price_cents)a
  @optional_fields ~w(
    kalshi_fill_id kalshi_order_id event_ticker market_title team_a team_b sport
    cost_cents fees_cents ai_recommendation ai_confidence ai_fair_value ai_edge
    ai_reasoning ai_key_factors ai_model web_context_summary status settlement_value
    payout_cents profit_cents roi_percent close_price_cents close_payout_cents
    placed_at game_date settled_at synced_at
  )a

  def changeset(bet, attrs) do
    bet
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:side, ~w(yes no))
    |> validate_inclusion(:action, ~w(buy sell))
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:contracts, greater_than: 0)
    |> validate_number(:price_cents, greater_than: 0, less_than: 100)
    |> calculate_cost()
    |> unique_constraint(:kalshi_fill_id)
  end

  def settle_changeset(bet, attrs) do
    bet
    |> cast(attrs, [:status, :settlement_value, :payout_cents, :profit_cents, :roi_percent, :settled_at])
    |> validate_inclusion(:status, ~w(won lost push))
    |> calculate_profit()
  end

  def close_changeset(bet, attrs) do
    bet
    |> cast(attrs, [:status, :close_price_cents, :close_payout_cents, :profit_cents, :roi_percent])
    |> put_change(:status, "sold")
    |> calculate_close_profit()
  end

  # Calculate cost from price and contracts
  defp calculate_cost(changeset) do
    price = get_field(changeset, :price_cents)
    contracts = get_field(changeset, :contracts)

    if price && contracts do
      put_change(changeset, :cost_cents, price * contracts)
    else
      changeset
    end
  end

  # Calculate profit after settlement
  defp calculate_profit(changeset) do
    status = get_change(changeset, :status) || get_field(changeset, :status)
    settlement = get_change(changeset, :settlement_value) || get_field(changeset, :settlement_value)
    contracts = get_field(changeset, :contracts)
    cost = get_field(changeset, :cost_cents)
    side = get_field(changeset, :side)
    fees = get_field(changeset, :fees_cents) || 0

    if status in ["won", "lost"] && contracts && cost do
      # Determine if bet won based on side and settlement
      won = case {side, settlement} do
        {"yes", 100} -> true
        {"no", 0} -> true
        _ -> false
      end

      payout = if won, do: contracts * 100, else: 0
      profit = payout - cost - fees
      roi = if cost > 0, do: Decimal.from_float(profit / cost * 100), else: Decimal.new(0)

      changeset
      |> put_change(:payout_cents, payout)
      |> put_change(:profit_cents, profit)
      |> put_change(:roi_percent, roi)
    else
      changeset
    end
  end

  # Calculate profit if sold before settlement
  defp calculate_close_profit(changeset) do
    close_price = get_change(changeset, :close_price_cents)
    contracts = get_field(changeset, :contracts)
    cost = get_field(changeset, :cost_cents)
    fees = get_field(changeset, :fees_cents) || 0

    if close_price && contracts && cost do
      payout = close_price * contracts
      profit = payout - cost - fees
      roi = if cost > 0, do: Decimal.from_float(profit / cost * 100), else: Decimal.new(0)

      changeset
      |> put_change(:close_payout_cents, payout)
      |> put_change(:profit_cents, profit)
      |> put_change(:roi_percent, roi)
    else
      changeset
    end
  end

  # Helper to check if bet won
  def won?(%__MODULE__{status: "won"}), do: true
  def won?(_), do: false

  def lost?(%__MODULE__{status: "lost"}), do: true
  def lost?(_), do: false

  def pending?(%__MODULE__{status: "pending"}), do: true
  def pending?(_), do: false

  def settled?(%__MODULE__{status: status}) when status in ["won", "lost", "push"], do: true
  def settled?(_), do: false
end
