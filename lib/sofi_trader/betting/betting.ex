defmodule SofiTrader.Betting do
  @moduledoc """
  Context module for sports betting operations.

  Provides functions to:
  - Create and track bets
  - Sync bets from Kalshi
  - Calculate statistics and performance metrics
  """

  import Ecto.Query
  alias SofiTrader.Repo
  alias SofiTrader.Betting.SportsBet

  # ========== CRUD Operations ==========

  @doc """
  Create a new sports bet.
  """
  def create_bet(attrs) do
    %SportsBet{}
    |> SportsBet.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a bet by ID.
  """
  def get_bet(id), do: Repo.get(SportsBet, id)

  @doc """
  Get a bet by Kalshi fill ID.
  """
  def get_bet_by_fill_id(fill_id) do
    Repo.get_by(SportsBet, kalshi_fill_id: fill_id)
  end

  @doc """
  Update a bet.
  """
  def update_bet(%SportsBet{} = bet, attrs) do
    bet
    |> SportsBet.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Settle a bet with outcome.
  """
  def settle_bet(%SportsBet{} = bet, settlement_value) do
    status = case {bet.side, settlement_value} do
      {"yes", 100} -> "won"
      {"yes", 0} -> "lost"
      {"no", 0} -> "won"
      {"no", 100} -> "lost"
      _ -> "push"
    end

    bet
    |> SportsBet.settle_changeset(%{
      status: status,
      settlement_value: settlement_value,
      settled_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Mark a bet as sold (closed before settlement).
  """
  def close_bet(%SportsBet{} = bet, close_price_cents) do
    bet
    |> SportsBet.close_changeset(%{close_price_cents: close_price_cents})
    |> Repo.update()
  end

  # ========== Query Functions ==========

  @doc """
  List all bets with optional filters.

  ## Options
    - `:status` - Filter by status ("pending", "won", "lost", etc.)
    - `:sport` - Filter by sport
    - `:since` - Only bets placed after this datetime
    - `:until` - Only bets placed before this datetime
    - `:ai_recommendation` - Filter by AI recommendation
    - `:limit` - Limit number of results
    - `:order` - Order by field (default: placed_at desc)
  """
  def list_bets(opts \\ []) do
    SportsBet
    |> apply_filters(opts)
    |> apply_order(opts)
    |> apply_limit(opts)
    |> Repo.all()
  end

  @doc """
  List pending bets (not yet settled).
  """
  def list_pending_bets(opts \\ []) do
    opts = Keyword.put(opts, :status, "pending")
    list_bets(opts)
  end

  @doc """
  List aggregated positions (fills grouped by market_ticker).

  Returns a list of maps with aggregated data per market.
  """
  def list_positions(opts \\ []) do
    list_bets(opts)
    |> aggregate_fills_by_market()
  end

  @doc """
  List aggregated pending positions.
  """
  def list_pending_positions(opts \\ []) do
    opts = Keyword.put(opts, :status, "pending")
    list_bets(opts)
    |> aggregate_fills_by_market()
  end

  @doc """
  Aggregate fills by market ticker into positions.

  For each market, calculates:
  - Total contracts
  - Weighted average price
  - Total cost
  - Total profit (for settled)
  - Overall status
  """
  def aggregate_fills_by_market(fills) do
    fills
    |> Enum.group_by(& &1.market_ticker)
    |> Enum.map(fn {_ticker, market_fills} ->
      aggregate_single_market(market_fills)
    end)
    |> Enum.sort_by(& &1.placed_at, {:desc, DateTime})
  end

  defp aggregate_single_market(fills) do
    first = hd(fills)
    total_contracts = fills |> Enum.map(& &1.contracts) |> Enum.sum()
    total_cost = fills |> Enum.map(& &1.cost_cents) |> Enum.sum()
    total_profit = fills |> Enum.map(& &1.profit_cents || 0) |> Enum.sum()

    # Weighted average price
    weighted_sum = fills |> Enum.map(fn f -> f.price_cents * f.contracts end) |> Enum.sum()
    avg_price = if total_contracts > 0, do: div(weighted_sum, total_contracts), else: 0

    # Determine overall status
    statuses = fills |> Enum.map(& &1.status) |> Enum.uniq()
    status = if length(statuses) == 1, do: hd(statuses), else: hd(statuses)

    # Use earliest placed_at for sorting
    earliest_placed = fills
    |> Enum.map(& &1.placed_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)

    # Calculate ROI
    roi = if total_cost > 0, do: Float.round(total_profit / total_cost * 100, 2), else: 0.0

    %{
      id: first.id,
      market_ticker: first.market_ticker,
      market_title: first.market_title,
      event_ticker: first.event_ticker,
      team_a: first.team_a,
      team_b: first.team_b,
      sport: first.sport,
      side: first.side,
      contracts: total_contracts,
      price_cents: avg_price,
      cost_cents: total_cost,
      fees_cents: fills |> Enum.map(& &1.fees_cents || 0) |> Enum.sum(),
      profit_cents: total_profit,
      roi_percent: roi,
      status: status,
      placed_at: earliest_placed,
      fill_count: length(fills),
      # AI fields from first fill (they should be same for all fills of same market)
      ai_recommendation: first.ai_recommendation,
      ai_confidence: first.ai_confidence
    }
  end

  @doc """
  List settled bets (won, lost, or push).
  """
  def list_settled_bets(opts \\ []) do
    SportsBet
    |> where([b], b.status in ["won", "lost", "push"])
    |> apply_settled_filters(opts)
    |> apply_order(opts)
    |> Repo.all()
  end

  defp apply_filters(query, opts) do
    query
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_sport(opts[:sport])
    |> maybe_filter_since(opts[:since])
    |> maybe_filter_until(opts[:until])
    |> maybe_filter_ai_recommendation(opts[:ai_recommendation])
  end

  # For settled bets, filter by settled_at instead of placed_at
  defp apply_settled_filters(query, opts) do
    query
    |> maybe_filter_sport(opts[:sport])
    |> maybe_filter_settled_since(opts[:since])
    |> maybe_filter_ai_recommendation(opts[:ai_recommendation])
  end

  defp maybe_filter_settled_since(query, nil), do: query
  defp maybe_filter_settled_since(query, since) do
    # Filter by placed_at (when bet was made on Kalshi) for historical analysis
    # This is more useful than settled_at which gets set during sync
    where(query, [b], not is_nil(b.placed_at) and b.placed_at >= ^since)
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [b], b.status == ^status)

  defp maybe_filter_sport(query, nil), do: query
  defp maybe_filter_sport(query, sport), do: where(query, [b], b.sport == ^to_string(sport))

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, since) do
    # For pending bets, filter by placed_at only
    # Bets without placed_at are excluded from time-filtered views
    where(query, [b], not is_nil(b.placed_at) and b.placed_at >= ^since)
  end

  defp maybe_filter_until(query, nil), do: query
  defp maybe_filter_until(query, until), do: where(query, [b], b.placed_at <= ^until)

  defp maybe_filter_ai_recommendation(query, nil), do: query
  defp maybe_filter_ai_recommendation(query, rec), do: where(query, [b], b.ai_recommendation == ^rec)

  defp apply_order(query, opts) do
    case opts[:order] do
      nil -> order_by(query, [b], desc: b.placed_at)
      field -> order_by(query, [b], desc: field(b, ^field))
    end
  end

  defp apply_limit(query, opts) do
    case opts[:limit] do
      nil -> query
      limit -> limit(query, ^limit)
    end
  end

  # ========== Statistics ==========

  @doc """
  Get comprehensive betting statistics using aggregated positions.

  Returns a map with:
  - Overall win rate, profit, ROI (based on unique positions, not fills)
  - Stats by sport
  - Stats by AI confidence level
  - Recent performance trends
  """
  def get_statistics(opts \\ []) do
    # Get settled bets and aggregate by market for accurate position counting
    bets = list_settled_bets(opts)
    positions = aggregate_fills_by_market(bets)

    %{
      overall: calculate_overall_stats_from_positions(positions),
      by_sport: calculate_stats_by_sport_from_positions(positions),
      by_ai_confidence: calculate_stats_by_confidence(bets),  # Keep using fills for AI stats
      by_ai_recommendation: calculate_stats_by_recommendation(bets),
      recent_trend: calculate_recent_trend_from_positions(positions)
    }
  end

  @doc """
  Calculate overall statistics from aggregated positions.
  """
  def calculate_overall_stats_from_positions(positions) do
    total = length(positions)

    if total == 0 do
      %{
        total_bets: 0,
        wins: 0,
        losses: 0,
        win_rate: 0.0,
        total_wagered_cents: 0,
        total_profit_cents: 0,
        roi_percent: 0.0,
        avg_bet_size_cents: 0,
        avg_profit_per_bet_cents: 0
      }
    else
      wins = Enum.count(positions, fn p -> p.status == "won" end)
      losses = Enum.count(positions, fn p -> p.status == "lost" end)

      total_wagered = positions |> Enum.map(& &1.cost_cents) |> Enum.sum()
      total_profit = positions |> Enum.map(& &1.profit_cents) |> Enum.sum()

      %{
        total_bets: total,
        wins: wins,
        losses: losses,
        win_rate: Float.round(wins / total * 100, 1),
        total_wagered_cents: total_wagered,
        total_profit_cents: total_profit,
        roi_percent: if(total_wagered > 0, do: Float.round(total_profit / total_wagered * 100, 2), else: 0.0),
        avg_bet_size_cents: div(total_wagered, total),
        avg_profit_per_bet_cents: div(total_profit, total)
      }
    end
  end

  @doc """
  Calculate statistics by sport from aggregated positions.
  """
  def calculate_stats_by_sport_from_positions(positions) do
    positions
    |> Enum.group_by(& &1.sport)
    |> Enum.map(fn {sport, sport_positions} ->
      {sport || "unknown", calculate_overall_stats_from_positions(sport_positions)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Calculate recent trend from aggregated positions.
  """
  def calculate_recent_trend_from_positions(positions) do
    now = DateTime.utc_now()

    %{
      last_7_days: calculate_period_stats_from_positions(positions, now, -7),
      last_30_days: calculate_period_stats_from_positions(positions, now, -30),
      last_90_days: calculate_period_stats_from_positions(positions, now, -90)
    }
  end

  defp calculate_period_stats_from_positions(positions, now, days) do
    cutoff = DateTime.add(now, days, :day)

    period_positions = Enum.filter(positions, fn pos ->
      pos.placed_at && DateTime.compare(pos.placed_at, cutoff) == :gt
    end)

    calculate_overall_stats_from_positions(period_positions)
  end

  @doc """
  Calculate overall statistics from settled bets.
  """
  def calculate_overall_stats(bets) do
    total = length(bets)

    if total == 0 do
      %{
        total_bets: 0,
        wins: 0,
        losses: 0,
        win_rate: 0.0,
        total_wagered_cents: 0,
        total_profit_cents: 0,
        roi_percent: 0.0,
        avg_bet_size_cents: 0,
        avg_profit_per_bet_cents: 0
      }
    else
      wins = Enum.count(bets, &SportsBet.won?/1)
      losses = Enum.count(bets, &SportsBet.lost?/1)

      total_wagered = bets |> Enum.map(& &1.cost_cents) |> Enum.sum()
      total_profit = bets |> Enum.map(& &1.profit_cents || 0) |> Enum.sum()

      %{
        total_bets: total,
        wins: wins,
        losses: losses,
        win_rate: Float.round(wins / total * 100, 1),
        total_wagered_cents: total_wagered,
        total_profit_cents: total_profit,
        roi_percent: if(total_wagered > 0, do: Float.round(total_profit / total_wagered * 100, 2), else: 0.0),
        avg_bet_size_cents: div(total_wagered, total),
        avg_profit_per_bet_cents: div(total_profit, total)
      }
    end
  end

  @doc """
  Calculate statistics grouped by sport.
  """
  def calculate_stats_by_sport(bets) do
    bets
    |> Enum.group_by(& &1.sport)
    |> Enum.map(fn {sport, sport_bets} ->
      {sport || "unknown", calculate_overall_stats(sport_bets)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Calculate statistics grouped by AI confidence level.
  """
  def calculate_stats_by_confidence(bets) do
    ai_bets = Enum.filter(bets, & &1.ai_confidence)

    confidence_buckets = %{
      high: Enum.filter(ai_bets, fn b ->
        conf = Decimal.to_float(b.ai_confidence)
        conf >= 0.8
      end),
      medium: Enum.filter(ai_bets, fn b ->
        conf = Decimal.to_float(b.ai_confidence)
        conf >= 0.6 && conf < 0.8
      end),
      low: Enum.filter(ai_bets, fn b ->
        conf = Decimal.to_float(b.ai_confidence)
        conf < 0.6
      end)
    }

    confidence_buckets
    |> Enum.map(fn {level, level_bets} ->
      {level, calculate_overall_stats(level_bets)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Calculate statistics grouped by AI recommendation.
  """
  def calculate_stats_by_recommendation(bets) do
    bets
    |> Enum.filter(& &1.ai_recommendation)
    |> Enum.group_by(& &1.ai_recommendation)
    |> Enum.map(fn {rec, rec_bets} ->
      {rec, calculate_overall_stats(rec_bets)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Calculate recent performance trend (last 7/30/90 days).
  """
  def calculate_recent_trend(bets) do
    now = DateTime.utc_now()

    %{
      last_7_days: calculate_period_stats(bets, now, -7),
      last_30_days: calculate_period_stats(bets, now, -30),
      last_90_days: calculate_period_stats(bets, now, -90)
    }
  end

  defp calculate_period_stats(bets, now, days) do
    cutoff = DateTime.add(now, days, :day)

    period_bets = Enum.filter(bets, fn bet ->
      bet.settled_at && DateTime.compare(bet.settled_at, cutoff) == :gt
    end)

    calculate_overall_stats(period_bets)
  end

  # ========== AI Analysis Statistics ==========

  @doc """
  Analyze AI prediction accuracy.

  Returns metrics on how accurate the AI recommendations have been.
  """
  def analyze_ai_accuracy(opts \\ []) do
    bets = list_settled_bets(opts) |> Enum.filter(& &1.ai_recommendation)

    if length(bets) == 0 do
      %{message: "No AI-driven bets found"}
    else
      # Bets where AI recommendation matched the bet side
      matching_bets = Enum.filter(bets, fn b ->
        b.ai_recommendation == b.side
      end)

      # Of matching bets, how many won?
      ai_correct = Enum.count(matching_bets, &SportsBet.won?/1)

      %{
        total_ai_bets: length(bets),
        ai_recommendations_followed: length(matching_bets),
        ai_correct_predictions: ai_correct,
        ai_accuracy: Float.round(ai_correct / max(length(matching_bets), 1) * 100, 1),
        # Profit from AI-recommended bets
        ai_profit_cents: matching_bets |> Enum.map(& &1.profit_cents || 0) |> Enum.sum(),
        # Compare to bets that went against AI
        against_ai_bets: length(bets) - length(matching_bets),
        against_ai_profit_cents: (bets -- matching_bets) |> Enum.map(& &1.profit_cents || 0) |> Enum.sum()
      }
    end
  end

  @doc """
  Get edge analysis - how accurate are the AI's edge estimates?
  """
  def analyze_ai_edge_accuracy(opts \\ []) do
    bets = list_settled_bets(opts)
    |> Enum.filter(& &1.ai_edge)

    if length(bets) == 0 do
      %{message: "No bets with AI edge data found"}
    else
      edge_buckets = %{
        "5-10¢" => Enum.filter(bets, fn b -> b.ai_edge >= 5 && b.ai_edge < 10 end),
        "10-15¢" => Enum.filter(bets, fn b -> b.ai_edge >= 10 && b.ai_edge < 15 end),
        "15-20¢" => Enum.filter(bets, fn b -> b.ai_edge >= 15 && b.ai_edge < 20 end),
        "20+¢" => Enum.filter(bets, fn b -> b.ai_edge >= 20 end)
      }

      edge_buckets
      |> Enum.map(fn {range, range_bets} ->
        stats = calculate_overall_stats(range_bets)
        {range, Map.put(stats, :expected_edge, get_avg_edge(range_bets))}
      end)
      |> Enum.into(%{})
    end
  end

  defp get_avg_edge(bets) when length(bets) == 0, do: 0
  defp get_avg_edge(bets) do
    bets
    |> Enum.map(& &1.ai_edge)
    |> Enum.sum()
    |> div(length(bets))
  end
end
