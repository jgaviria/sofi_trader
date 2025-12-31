defmodule SofiTrader.Betting.KalshiSync do
  @moduledoc """
  Syncs all bets from Kalshi API.

  This module:
  - Pulls fills (executed trades) from Kalshi
  - Creates bet records with market info
  - Checks for settlements and updates bet outcomes
  - Categorizes bets by type (sports, politics, crypto, etc.)
  """

  require Logger

  alias SofiTrader.Betting
  alias SofiTrader.Betting.SportsBet
  alias SofiTrader.Kalshi.{Orders, Markets}

  @doc """
  Sync all fills from Kalshi with pagination.

  Options:
    - `:since` - Only sync fills after this timestamp
    - `:limit` - Max fills per page (default: 100)
    - `:max_pages` - Max pages to fetch (default: 50, set to nil for unlimited)
  """
  def sync_fills(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    max_pages = Keyword.get(opts, :max_pages, 50)

    Logger.info("[KalshiSync] Starting fill sync (paginated)...")

    case fetch_all_fills(limit, max_pages) do
      {:ok, all_fills} ->
        Logger.info("[KalshiSync] Found #{length(all_fills)} total fills")

        results = Enum.map(all_fills, &sync_single_fill/1)

        synced = Enum.count(results, fn
          {:ok, _} -> true
          {:exists, _} -> true
          _ -> false
        end)

        new_bets = Enum.count(results, &match?({:ok, _}, &1))
        errors = Enum.count(results, &match?({:error, _}, &1))

        Logger.info("[KalshiSync] Synced #{synced} fills (#{new_bets} new bets, #{errors} errors)")
        {:ok, %{total: length(all_fills), synced: synced, new: new_bets, errors: errors}}

      {:error, reason} ->
        Logger.error("[KalshiSync] Failed to fetch fills: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Fetch all fills with pagination
  defp fetch_all_fills(limit, max_pages) do
    fetch_all_fills(limit, max_pages, nil, [], 1)
  end

  defp fetch_all_fills(_limit, max_pages, _cursor, acc, page) when is_integer(max_pages) and page > max_pages do
    {:ok, acc}
  end

  defp fetch_all_fills(limit, max_pages, cursor, acc, page) do
    opts = [limit: limit]
    opts = if cursor, do: Keyword.put(opts, :cursor, cursor), else: opts

    case Orders.list_fills(opts) do
      {:ok, %{"fills" => fills, "cursor" => next_cursor}} when is_list(fills) and length(fills) > 0 ->
        Logger.info("[KalshiSync] Page #{page}: fetched #{length(fills)} fills")
        fetch_all_fills(limit, max_pages, next_cursor, acc ++ fills, page + 1)

      {:ok, %{"fills" => fills}} when is_list(fills) and length(fills) > 0 ->
        # No more pages
        {:ok, acc ++ fills}

      {:ok, %{"fills" => []}} ->
        # Empty page, we're done
        {:ok, acc}

      {:ok, %{"fills" => fills}} when is_list(fills) ->
        {:ok, acc ++ fills}

      {:ok, _response} ->
        # Unexpected format but we have accumulated results
        {:ok, acc}

      {:error, reason} ->
        if length(acc) > 0 do
          # Return what we have
          Logger.warning("[KalshiSync] Pagination stopped due to error, returning #{length(acc)} fills")
          {:ok, acc}
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Sync settlements - check pending bets and update outcomes.
  """
  def sync_settlements do
    Logger.info("[KalshiSync] Checking for settlements...")

    pending_bets = Betting.list_pending_bets()
    Logger.info("[KalshiSync] Found #{length(pending_bets)} pending bets to check")

    results = Enum.map(pending_bets, &check_and_settle_bet/1)

    settled = Enum.count(results, &match?({:ok, _}, &1))
    Logger.info("[KalshiSync] Settled #{settled} bets")

    {:ok, %{checked: length(pending_bets), settled: settled}}
  end

  @doc """
  Full sync - fills and settlements.
  """
  def full_sync(opts \\ []) do
    with {:ok, fill_result} <- sync_fills(opts),
         {:ok, settlement_result} <- sync_settlements() do
      {:ok, %{
        fills: fill_result,
        settlements: settlement_result
      }}
    end
  end

  # Sync a single fill to a bet record
  defp sync_single_fill(fill) do
    fill_id = fill["trade_id"] || fill["id"]

    # Check if we already have this fill
    case Betting.get_bet_by_fill_id(fill_id) do
      nil ->
        create_bet_from_fill(fill)

      existing ->
        {:exists, existing}
    end
  end

  # Create a SportsBet from a Kalshi fill
  defp create_bet_from_fill(fill) do
    ticker = fill["ticker"]

    # Get market info for additional context
    market_info = case Markets.get_market(ticker) do
      {:ok, %{"market" => market}} -> market
      {:ok, market} when is_map(market) -> market
      _ -> %{}
    end

    # Parse sport and teams from ticker/title
    sport = detect_sport_from_ticker(ticker)
    {team_a, team_b} = parse_teams_from_market(market_info)

    # Calculate cost
    price = fill["yes_price"] || fill["no_price"] || 50
    contracts = fill["count"] || 1
    cost = price * contracts

    attrs = %{
      kalshi_fill_id: fill["trade_id"] || fill["id"],
      kalshi_order_id: fill["order_id"],
      market_ticker: ticker,
      event_ticker: market_info["event_ticker"],
      market_title: market_info["title"],
      team_a: team_a,
      team_b: team_b,
      sport: to_string(sport),
      side: fill["side"],
      action: fill["action"] || "buy",
      contracts: contracts,
      price_cents: price,
      cost_cents: cost,
      fees_cents: 0,  # Kalshi doesn't return fees in fill data
      placed_at: parse_timestamp(fill["created_time"]),
      synced_at: DateTime.utc_now()
    }

    Betting.create_bet(attrs)
  end

  # Check if a bet's market has settled and update accordingly
  defp check_and_settle_bet(%SportsBet{} = bet) do
    case Markets.get_market(bet.market_ticker) do
      {:ok, %{"market" => market}} ->
        maybe_settle_from_market(bet, market)

      {:ok, market} when is_map(market) ->
        maybe_settle_from_market(bet, market)

      {:error, reason} ->
        Logger.warning("[KalshiSync] Failed to check market #{bet.market_ticker}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_settle_from_market(bet, market) do
    case market["result"] do
      "yes" ->
        Betting.settle_bet(bet, 100)

      "no" ->
        Betting.settle_bet(bet, 0)

      nil ->
        # Not settled yet
        {:ok, :pending}

      other ->
        Logger.info("[KalshiSync] Market #{bet.market_ticker} has result: #{other}")
        {:ok, :pending}
    end
  end

  # Detect category from ticker prefix
  defp detect_sport_from_ticker(nil), do: :other
  defp detect_sport_from_ticker(ticker) do
    ticker_up = String.upcase(ticker)

    cond do
      # Sports - NFL/College Football
      String.contains?(ticker_up, "NFL") || String.contains?(ticker_up, "NCAAF") -> :nfl

      # Sports - NBA/College Basketball
      String.contains?(ticker_up, "NBA") || String.contains?(ticker_up, "WNBA") || String.contains?(ticker_up, "NCAAB") -> :nba

      # Sports - NHL
      String.contains?(ticker_up, "NHL") -> :nhl

      # Sports - MLB
      String.contains?(ticker_up, "MLB") -> :mlb

      # Sports - Soccer
      String.contains?(ticker_up, "EPL") || String.contains?(ticker_up, "LALIGA") ||
      String.contains?(ticker_up, "BUNDES") || String.contains?(ticker_up, "SERIE") ||
      String.contains?(ticker_up, "LIGUE") || String.contains?(ticker_up, "MLS") ||
      String.contains?(ticker_up, "UCL") || String.contains?(ticker_up, "UEL") ||
      String.contains?(ticker_up, "AFCON") || String.contains?(ticker_up, "FIFA") ||
      String.contains?(ticker_up, "UEFA") || String.contains?(ticker_up, "SOCCER") -> :soccer

      # Crypto
      String.contains?(ticker_up, "BTC") || String.contains?(ticker_up, "ETH") ||
      String.contains?(ticker_up, "CRYPTO") || String.contains?(ticker_up, "BITCOIN") ||
      String.contains?(ticker_up, "SOL") || String.contains?(ticker_up, "XRP") -> :crypto

      # Politics
      String.contains?(ticker_up, "PRES") || String.contains?(ticker_up, "SENATE") ||
      String.contains?(ticker_up, "HOUSE") || String.contains?(ticker_up, "GOV") ||
      String.contains?(ticker_up, "POTUS") || String.contains?(ticker_up, "ELECTION") ||
      String.contains?(ticker_up, "TRUMP") || String.contains?(ticker_up, "BIDEN") ||
      String.contains?(ticker_up, "DEM") || String.contains?(ticker_up, "REP") ||
      String.contains?(ticker_up, "CONGRESS") || String.contains?(ticker_up, "VOTE") -> :politics

      # Economics/Fed
      String.contains?(ticker_up, "FED") || String.contains?(ticker_up, "FOMC") ||
      String.contains?(ticker_up, "CPI") || String.contains?(ticker_up, "GDP") ||
      String.contains?(ticker_up, "RATE") || String.contains?(ticker_up, "INFLATION") ||
      String.contains?(ticker_up, "JOBS") || String.contains?(ticker_up, "UNEMPLOYMENT") ||
      String.contains?(ticker_up, "ECON") -> :economics

      # Weather
      String.contains?(ticker_up, "WEATHER") || String.contains?(ticker_up, "TEMP") ||
      String.contains?(ticker_up, "HURRICANE") || String.contains?(ticker_up, "STORM") ||
      String.contains?(ticker_up, "SNOW") || String.contains?(ticker_up, "RAIN") -> :weather

      # Tech/Companies
      String.contains?(ticker_up, "AAPL") || String.contains?(ticker_up, "TSLA") ||
      String.contains?(ticker_up, "NVDA") || String.contains?(ticker_up, "META") ||
      String.contains?(ticker_up, "GOOG") || String.contains?(ticker_up, "MSFT") ||
      String.contains?(ticker_up, "AMZN") || String.contains?(ticker_up, "STOCK") -> :stocks

      # Entertainment/Awards
      String.contains?(ticker_up, "OSCAR") || String.contains?(ticker_up, "EMMY") ||
      String.contains?(ticker_up, "GRAMMY") || String.contains?(ticker_up, "AWARD") ||
      String.contains?(ticker_up, "MOVIE") || String.contains?(ticker_up, "TV") -> :entertainment

      # Science/Space
      String.contains?(ticker_up, "NASA") || String.contains?(ticker_up, "SPACE") ||
      String.contains?(ticker_up, "MARS") || String.contains?(ticker_up, "MOON") ||
      String.contains?(ticker_up, "ROCKET") || String.contains?(ticker_up, "LAUNCH") -> :science

      # Default
      true -> :other
    end
  end

  # Parse teams from market info
  defp parse_teams_from_market(market) when map_size(market) == 0, do: {nil, nil}
  defp parse_teams_from_market(market) do
    title = market["title"] || ""

    cond do
      String.contains?(title, " vs ") ->
        case Regex.run(~r/(.+?) vs (.+?) Winner\??/, title) do
          [_, team_a, team_b] -> {String.trim(team_a), String.trim(team_b)}
          _ -> {nil, nil}
        end

      String.contains?(title, " at ") ->
        case Regex.run(~r/(.+?) at (.+?) Winner\??/, title) do
          [_, team_a, team_b] -> {String.trim(team_a), String.trim(team_b)}
          _ -> {nil, nil}
        end

      true ->
        {nil, nil}
    end
  end

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_timestamp(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end
end
