defmodule SofiTrader.AI.SportsScanner do
  @moduledoc """
  Scans Kalshi markets for sports-related events.

  Identifies markets related to NFL, NBA, MLB, NHL, soccer, and other sports
  that can be analyzed by AI for underpriced bets.

  ## Usage

      # Scan all sports markets
      {:ok, markets} = SportsScanner.scan()

      # Scan specific sport
      {:ok, markets} = SportsScanner.scan(sport: :nfl)

      # Scan with filters
      {:ok, markets} = SportsScanner.scan(
        sport: :nba,
        min_volume: 1000,
        settling_within_hours: 24
      )
  """

  require Logger

  alias SofiTrader.Kalshi.Markets

  # Series tickers for simple game markets (Team A vs Team B)
  # Discovered via Markets.list_series() - actual Kalshi series names
  @game_series [
    # Soccer/Football
    "KXEPLGAME",        # English Premier League
    "KXMLSGAME",        # MLS Soccer
    "KXLALIGAGAME",     # La Liga
    "KXBUNDESLIGAGAME", # Bundesliga
    "KXSERIAGAME",      # Serie A
    "KXLIGUE1GAME",     # Ligue 1
    "KXUCLGAME",        # Champions League
    "KXFIFAGAME",       # FIFA/International Soccer
    "KXALEAGUEGAME",    # Australian A-League
    "KXAFCONGAME",      # Africa Cup of Nations
    # American Football (NFL + College)
    "KXNFLGAME",        # NFL
    "KXNCAAFGAME",      # College Football (FBS)
    "KXNCAAFCSGAME",    # College Football (FCS)
    "KXNCAAFD3GAME",    # College Football (D3)
    # Basketball (NBA/WNBA + College)
    "KXNBAGAME",        # NBA
    "KXWNBAGAME",       # WNBA
    "KXNCAABGAME",      # College Basketball
    # Hockey
    "KXNHLGAME",        # NHL Hockey
    # Baseball
    "KXMLBGAME"         # MLB Baseball
  ]

  # Known sports-related keywords and tickers on Kalshi
  # NOTE: Avoid generic words like "win", "game", "match" that match political markets
  @sports_keywords [
    # American Football
    "nfl", "football", "super bowl", "touchdown", "quarterback", "49ers", "chiefs", "eagles",
    "cowboys", "packers", "bills", "ravens", "lions", "steelers",
    # Basketball
    "nba", "basketball", "lakers", "celtics", "warriors", "bucks", "nuggets", "heat",
    "knicks", "suns", "76ers", "cavaliers", "thunder", "timberwolves",
    # Baseball
    "mlb", "baseball", "world series", "home run", "yankees", "dodgers", "braves",
    "astros", "phillies", "rangers", "cubs", "red sox", "mets",
    # Hockey
    "nhl", "hockey", "stanley cup", "bruins", "avalanche", "oilers", "panthers",
    # Soccer
    "soccer", "mls", "premier league", "fifa", "la liga", "bundesliga", "serie a",
    "champions league", "arsenal", "manchester", "liverpool", "chelsea", "real madrid",
    # Golf
    "golf", "pga", "masters tournament", "british open", "lpga",
    # Tennis
    "tennis", "wimbledon", "australian open", "french open", "atp", "wta",
    # Boxing/MMA
    "ufc", "boxing", "mma", "bellator",
    # Racing
    "nascar", "f1", "formula 1", "indycar", "daytona",
    # College Sports
    "ncaa", "march madness", "college football", "cfp",
    # Specific sports event indicators
    "d/st", "spread", "moneyline", "over/under", "parlay"
  ]

  # Sport categories for filtering
  @sport_categories %{
    nfl: ["nfl", "football", "super bowl", "touchdown", "quarterback", "49ers", "chiefs",
          "eagles", "cowboys", "packers", "bills", "ravens", "lions", "steelers", "d/st"],
    nba: ["nba", "basketball", "lakers", "celtics", "warriors", "bucks", "nuggets", "heat",
          "knicks", "suns", "76ers", "cavaliers", "thunder", "timberwolves"],
    mlb: ["mlb", "baseball", "world series", "yankees", "dodgers", "braves", "astros"],
    nhl: ["nhl", "hockey", "stanley cup", "bruins", "avalanche", "oilers", "panthers"],
    soccer: ["soccer", "mls", "premier league", "fifa", "la liga", "bundesliga", "serie a",
             "champions league", "arsenal", "manchester", "liverpool", "chelsea"],
    golf: ["golf", "pga", "masters tournament", "british open", "lpga"],
    tennis: ["tennis", "wimbledon", "australian open", "french open", "atp", "wta"],
    mma: ["ufc", "boxing", "mma", "bellator"],
    racing: ["nascar", "f1", "formula 1", "indycar", "daytona"]
  }

  @doc """
  Scan Kalshi for simple game markets (Team A vs Team B).

  ## Options
    - `:sport` - Filter by specific sport (:nfl, :nba, :mlb, :nhl, :soccer, etc.)
    - `:status` - Market status filter (default: "open")
    - `:min_volume` - Minimum volume filter
    - `:settling_within_hours` - Only markets settling within N hours
    - `:limit` - Max markets to return per series (default: 50)

  ## Returns
    - `{:ok, [market]}` - List of simple game markets
    - `{:error, reason}` - If scan fails
  """
  def scan(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    sport_filter = Keyword.get(opts, :sport)

    Logger.info("[SportsScanner] Scanning for simple game markets...")

    # Fetch from each game series
    all_markets =
      @game_series
      |> maybe_filter_series(sport_filter)
      |> Enum.flat_map(fn series ->
        case Markets.list_markets(series_ticker: series, status: "open", limit: limit) do
          {:ok, %{"markets" => markets}} -> markets
          {:ok, markets} when is_list(markets) -> markets
          _ -> []
        end
      end)

    filtered = filter_game_markets(all_markets, opts)
    Logger.info("[SportsScanner] Found #{length(filtered)} game markets")
    {:ok, filtered}
  end

  # Filter series by sport type
  defp maybe_filter_series(series, nil), do: series
  defp maybe_filter_series(series, :soccer) do
    Enum.filter(series, fn s ->
      String.contains?(s, "EPL") || String.contains?(s, "FIFA") || String.contains?(s, "MLS") ||
      String.contains?(s, "LALIGA") || String.contains?(s, "BUNDES") || String.contains?(s, "SERIA") ||
      String.contains?(s, "LIGUE") || String.contains?(s, "UCL") || String.contains?(s, "ALEAGUE") ||
      String.contains?(s, "AFCON")
    end)
  end
  defp maybe_filter_series(series, :nfl) do
    # Include NFL and College Football
    Enum.filter(series, fn s ->
      String.contains?(s, "NFLGAME") || String.contains?(s, "NCAAFGAME") ||
      String.contains?(s, "NCAAFCSGAME") || String.contains?(s, "NCAAFD3GAME")
    end)
  end
  defp maybe_filter_series(series, :nba) do
    # Include NBA, WNBA, and College Basketball
    Enum.filter(series, fn s ->
      String.contains?(s, "NBAGAME") || String.contains?(s, "WNBAGAME") || String.contains?(s, "NCAABGAME")
    end)
  end
  defp maybe_filter_series(series, :nhl), do: Enum.filter(series, &String.contains?(&1, "NHL"))
  defp maybe_filter_series(series, :mlb), do: Enum.filter(series, &String.contains?(&1, "MLB"))
  defp maybe_filter_series(_series, _sport), do: []

  @doc """
  Get list of available sport categories.
  """
  def sport_categories, do: Map.keys(@sport_categories)

  # Kalshi ticker prefixes that indicate sports markets
  # Format: KXMVE{SPORT}... or KXMV{SPORT}...
  @sports_ticker_patterns [
    "kxmvenfl",      # NFL markets
    "kxmvnfl",       # NFL alt format
    "kxmvenba",      # NBA markets
    "kxmvnba",       # NBA alt format
    "kxmvemlb",      # MLB markets
    "kxmvmlb",       # MLB alt format
    "kxmvenhl",      # NHL markets
    "kxmvnhl",       # NHL alt format
    "kxmvesports",   # Multi-sport markets (parlays)
    "kxmvsoccer",    # Soccer markets
    "kxmvgolf",      # Golf markets
    "kxmvtennis",    # Tennis markets
    "kxmvufc",       # UFC/MMA markets
    "kxmvmma",       # MMA markets
    "kxmvnascar",    # NASCAR markets
    "kxmvf1",        # F1 markets
    "kxmvncaa"       # College sports
  ]

  @doc """
  Check if a market title/ticker appears to be sports-related.
  """
  def sports_market?(market) do
    ticker = String.downcase(market["ticker"] || "")

    # Check Kalshi sports ticker patterns (most reliable)
    ticker_is_sports = Enum.any?(@sports_ticker_patterns, fn pattern ->
      String.starts_with?(ticker, pattern)
    end)

    if ticker_is_sports do
      true
    else
      # Fall back to keyword matching
      title = String.downcase(market["title"] || "")
      Enum.any?(@sports_keywords, fn keyword ->
        String.contains?(title, keyword) || String.contains?(ticker, keyword)
      end)
    end
  end

  # NBA player names for categorization
  @nba_players ["jaylen brown", "lamelo ball", "james harden", "trae young", "jayson tatum",
                "paolo banchero", "scottie barnes", "jalen johnson", "cj mccollum", "derrick white",
                "kawhi leonard", "pascal siakam", "deni avdija", "josh giddey", "cade cunningham",
                "zion williamson", "desmond bane", "lauri markkanen", "anthony edwards",
                # Additional common NBA players
                "nikola jokić", "nikola jokic", "jalen brunson", "karl-anthony towns", "jamal murray",
                "og anunoby", "luka doncic", "luka dončić", "stephen curry", "lebron james",
                "kevin durant", "giannis antetokounmpo", "joel embiid", "damian lillard",
                "devin booker", "donovan mitchell", "tyrese haliburton", "shai gilgeous-alexander",
                "victor wembanyama", "ja morant", "darius garland", "evan mobley", "franz wagner"]

  # NFL player names for categorization
  @nfl_players ["sam darnold", "justin herbert", "jaxson dart", "matthew stafford", "bryce young",
                "c.j. stroud", "trevor lawrence", "drake maye", "derrick henry", "christian mccaffrey",
                "travis etienne", "breece hall", "chase brown", "bijan robinson", "omarion hampton",
                "ladd mcconkey", "puka nacua", "stefon diggs", "ja'marr chase", "nico collins",
                # Additional common NFL players
                "baker mayfield", "tyler huntley", "josh jacobs", "mark andrews", "zay flowers",
                "romeo doubs", "dontayvion wicks", "jayden reed", "isaiah likely", "jaxon smith-njigba",
                "khalil shakir", "juwan johnson", "patrick mahomes", "joe burrow", "jalen hurts",
                "josh allen", "lamar jackson", "dak prescott", "tua tagovailoa", "ceedee lamb",
                "tyreek hill", "davante adams", "a.j. brown", "garrett wilson", "brock bowers",
                "travis kelce", "george kittle", "deebo samuel", "saquon barkley", "alvin kamara"]

  @doc """
  Categorize a market into a sport type.
  """
  def categorize_sport(market) do
    title = String.downcase(market["title"] || "")
    ticker = String.downcase(market["ticker"] || "")

    # Check ticker prefix first for most accurate categorization
    cond do
      String.starts_with?(ticker, "kxmvenfl") || String.starts_with?(ticker, "kxmvnfl") -> :nfl
      String.starts_with?(ticker, "kxmvenba") || String.starts_with?(ticker, "kxmvnba") -> :nba
      String.starts_with?(ticker, "kxmvemlb") || String.starts_with?(ticker, "kxmvmlb") -> :mlb
      String.starts_with?(ticker, "kxmvenhl") || String.starts_with?(ticker, "kxmvnhl") -> :nhl
      String.starts_with?(ticker, "kxmvsoccer") -> :soccer
      String.starts_with?(ticker, "kxmvgolf") -> :golf
      String.starts_with?(ticker, "kxmvtennis") -> :tennis
      String.starts_with?(ticker, "kxmvufc") || String.starts_with?(ticker, "kxmvmma") -> :mma
      String.starts_with?(ticker, "kxmvnascar") || String.starts_with?(ticker, "kxmvf1") -> :racing
      String.starts_with?(ticker, "kxmvncaa") ->
        # NCAA can be football or basketball - detect from title
        cond do
          String.contains?(title, "basketball") || String.contains?(title, "march madness") -> :nba
          String.contains?(title, "football") || String.contains?(title, "cfp") -> :nfl
          true -> :nfl  # Default to football for NCAA
        end

      # For multi-sport markets, detect by player names in title
      String.starts_with?(ticker, "kxmvesports") ->
        cond do
          Enum.any?(@nba_players, &String.contains?(title, &1)) -> :nba
          Enum.any?(@nfl_players, &String.contains?(title, &1)) -> :nfl
          # Check for NBA team names/cities
          String.contains?(title, "boston") || String.contains?(title, "detroit") ||
          String.contains?(title, "orlando") || String.contains?(title, "toronto") ||
          String.contains?(title, "phoenix") || String.contains?(title, "atlanta") ||
          String.contains?(title, "denver") || String.contains?(title, "knicks") ||
          String.contains?(title, "new york") || String.contains?(title, "lakers") ||
          String.contains?(title, "warriors") || String.contains?(title, "celtics") ||
          String.contains?(title, "bucks") || String.contains?(title, "nuggets") ||
          String.contains?(title, "heat") || String.contains?(title, "suns") ||
          String.contains?(title, "timberwolves") || String.contains?(title, "minnesota") ||
          String.contains?(title, "san antonio") || String.contains?(title, "memphis") ||
          String.contains?(title, "cleveland") || String.contains?(title, "indiana") -> :nba
          # Check for NFL team names/cities
          String.contains?(title, "green bay") || String.contains?(title, "pittsburgh") ||
          String.contains?(title, "baltimore") || String.contains?(title, "cincinnati") ||
          String.contains?(title, "new england") || String.contains?(title, "jacksonville") ||
          String.contains?(title, "houston") || String.contains?(title, "cowboys") ||
          String.contains?(title, "eagles") || String.contains?(title, "chiefs") ||
          String.contains?(title, "ravens") || String.contains?(title, "steelers") ||
          String.contains?(title, "packers") || String.contains?(title, "bills") -> :nfl
          true -> :other
        end

      # Fall back to keyword matching
      true ->
        text = title <> " " <> ticker
        Enum.find_value(@sport_categories, :other, fn {sport, keywords} ->
          if Enum.any?(keywords, &String.contains?(text, &1)) do
            sport
          end
        end)
    end
  end

  @doc """
  Format a market for AI analysis with all relevant data.
  """
  def format_for_analysis(market) do
    yes_bid = market["yes_bid"] || 0
    yes_ask = market["yes_ask"] || 100
    no_bid = market["no_bid"] || 0
    no_ask = market["no_ask"] || 100

    # Calculate spread for display
    yes_spread = yes_ask - yes_bid
    no_spread = no_ask - no_bid

    # Best tradeable price (what you'd pay to enter)
    best_yes_price = if yes_ask < 100, do: yes_ask, else: nil
    best_no_price = if no_ask < 100, do: no_ask, else: nil

    %{
      ticker: market["ticker"],
      title: market["title"],
      subtitle: market["subtitle"],
      yes_bid: yes_bid,
      yes_ask: yes_ask,
      no_bid: no_bid,
      no_ask: no_ask,
      yes_spread: yes_spread,
      no_spread: no_spread,
      best_yes_price: best_yes_price,
      best_no_price: best_no_price,
      last_price: market["last_price"],
      volume: market["volume"] || 0,
      open_interest: market["open_interest"] || 0,
      liquidity: market["liquidity"] || 0,
      close_time: market["close_time"] || market["expiration_time"],
      status: market["status"],
      sport: categorize_sport(market),
      rules_primary: market["rules_primary"],
      rules_secondary: market["rules_secondary"]
    }
  end

  # Private functions

  # Filter for simple game markets (Team vs Team)
  defp filter_game_markets(markets, opts) do
    min_volume = Keyword.get(opts, :min_volume, 0)
    settling_hours = Keyword.get(opts, :settling_within_hours)

    markets
    |> Enum.filter(&is_simple_game?/1)
    |> Enum.filter(&has_reasonable_price?/1)
    |> Enum.filter(&is_not_finished?/1)  # Filter out finished games
    |> maybe_filter_volume(min_volume)
    |> maybe_filter_settling(settling_hours)
    |> Enum.map(&format_game_for_analysis/1)
    |> Enum.uniq_by(fn m -> {m.title, m.outcome} end)  # Remove duplicate outcomes
    |> Enum.sort_by(&game_sort_key/1)  # Sort by date (today first), then volume
  end

  # Sort key: prioritize today's games, then tomorrow, then by volume
  # Game date is extracted from ticker (e.g., KXNCAAFGAME-25DEC27 = Dec 27, 2025)
  defp game_sort_key(market) do
    today = Date.utc_today()

    # Try to extract date from ticker (format: 25DEC27 = Dec 27, 2025)
    game_date = parse_game_date_from_ticker(market.ticker) || today

    days_until = Date.diff(game_date, today)

    # Priority buckets based on game date
    priority = cond do
      days_until < 0 -> 4       # Past (shouldn't happen, but safety)
      days_until == 0 -> 0      # Today
      days_until == 1 -> 1      # Tomorrow
      days_until <= 7 -> 2      # This week
      true -> 3                 # Later
    end

    # Sort by: priority first, then by date (earlier first), then by volume (higher first)
    {priority, days_until, -market.volume}
  end

  # Parse game date from ticker like "KXNCAAFGAME-25DEC27..." or "KXNHLGAME-25DEC27..."
  defp parse_game_date_from_ticker(ticker) when is_binary(ticker) do
    # Look for pattern like 25DEC27 (year 2025, Dec 27)
    case Regex.run(~r/(\d{2})([A-Z]{3})(\d{2})/, String.upcase(ticker)) do
      [_, year_short, month_str, day] ->
        month = case month_str do
          "JAN" -> 1; "FEB" -> 2; "MAR" -> 3; "APR" -> 4
          "MAY" -> 5; "JUN" -> 6; "JUL" -> 7; "AUG" -> 8
          "SEP" -> 9; "OCT" -> 10; "NOV" -> 11; "DEC" -> 12
          _ -> nil
        end

        if month do
          year = 2000 + String.to_integer(year_short)
          case Date.new(year, month, String.to_integer(day)) do
            {:ok, date} -> date
            _ -> nil
          end
        else
          nil
        end
      _ -> nil
    end
  end
  defp parse_game_date_from_ticker(_), do: nil

  # Filter out games that have already finished (more than 3 hours past close time)
  defp is_not_finished?(market) do
    close_time = market["close_time"] || market["expiration_time"]

    case close_time do
      nil -> true
      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} ->
            DateTime.diff(DateTime.utc_now(), dt, :hour) < 3
          _ -> true
        end
      ts when is_integer(ts) ->
        case DateTime.from_unix(ts) do
          {:ok, dt} ->
            DateTime.diff(DateTime.utc_now(), dt, :hour) < 3
          _ -> true
        end
      _ -> true
    end
  end

  defp is_simple_game?(market) do
    title = market["title"] || ""
    # Simple game markets have "vs" and "Winner?" pattern
    String.contains?(title, " vs ") || String.contains?(title, "Winner")
  end

  defp format_game_for_analysis(market) do
    title = market["title"] || ""
    ticker = market["ticker"] || ""
    yes_bid = market["yes_bid"] || 0
    yes_ask = market["yes_ask"] || 100
    no_bid = market["no_bid"] || 0
    no_ask = market["no_ask"] || 100

    # Parse the game title to extract teams
    {team_a, team_b, outcome} = parse_game_title(title)

    # Determine sport from series ticker
    sport = categorize_game_sport(ticker)

    # Parse game date from ticker for accurate display
    game_date = parse_game_date_from_ticker(ticker)

    %{
      ticker: ticker,
      title: title,
      team_a: team_a,
      team_b: team_b,
      outcome: outcome,  # Which outcome this market represents
      subtitle: market["subtitle"],
      yes_bid: yes_bid,
      yes_ask: yes_ask,
      no_bid: no_bid,
      no_ask: no_ask,
      yes_spread: yes_ask - yes_bid,
      no_spread: no_ask - no_bid,
      best_yes_price: if(yes_ask < 100, do: yes_ask, else: nil),
      best_no_price: if(no_ask < 100, do: no_ask, else: nil),
      last_price: market["last_price"],
      volume: market["volume"] || 0,
      open_interest: market["open_interest"] || 0,
      liquidity: market["liquidity"] || 0,
      close_time: market["close_time"] || market["expiration_time"],
      game_date: game_date,  # Actual game date parsed from ticker
      status: market["status"],
      sport: sport,
      rules_primary: market["rules_primary"],
      rules_secondary: market["rules_secondary"]
    }
  end

  defp parse_game_title(title) do
    cond do
      # "Team A vs Team B Winner?" with outcome being one team
      String.contains?(title, " vs ") && String.contains?(title, "Winner") ->
        # Extract teams from "Arsenal vs Liverpool Winner?"
        case Regex.run(~r/(.+?) vs (.+?) Winner\?/, title) do
          [_, team_a, team_b] -> {team_a, team_b, title}
          _ -> {title, nil, title}
        end

      # Just "Team wins" or similar
      String.contains?(title, " wins") ->
        {title, nil, title}

      true ->
        {title, nil, title}
    end
  end

  defp categorize_game_sport(ticker) do
    ticker_up = String.upcase(ticker)
    cond do
      # Soccer
      String.contains?(ticker_up, "EPL") -> :soccer
      String.contains?(ticker_up, "FIFA") -> :soccer
      String.contains?(ticker_up, "MLS") -> :soccer
      String.contains?(ticker_up, "LALIGA") -> :soccer
      String.contains?(ticker_up, "BUNDES") -> :soccer
      String.contains?(ticker_up, "SERIA") -> :soccer
      String.contains?(ticker_up, "LIGUE") -> :soccer
      String.contains?(ticker_up, "UCL") -> :soccer
      String.contains?(ticker_up, "ALEAGUE") -> :soccer
      String.contains?(ticker_up, "AFCON") -> :soccer
      # Hockey
      String.contains?(ticker_up, "NHL") -> :nhl
      # Baseball
      String.contains?(ticker_up, "MLB") -> :mlb
      # Basketball (pro and college)
      String.contains?(ticker_up, "NBAGAME") -> :nba
      String.contains?(ticker_up, "WNBAGAME") -> :nba
      String.contains?(ticker_up, "NCAABGAME") -> :nba
      # Football (pro and college) - check NCAAF before NBA to avoid false matches
      String.contains?(ticker_up, "NFLGAME") -> :nfl
      String.contains?(ticker_up, "NCAAFGAME") -> :nfl
      String.contains?(ticker_up, "NCAAFCSGAME") -> :nfl
      String.contains?(ticker_up, "NCAAFD3GAME") -> :nfl
      true -> :other
    end
  end

  # Legacy filter for parlay markets (kept for backwards compatibility)
  defp filter_sports_markets(markets, opts) do
    sport_filter = Keyword.get(opts, :sport)
    min_volume = Keyword.get(opts, :min_volume, 0)  # Default: don't require volume
    settling_hours = Keyword.get(opts, :settling_within_hours)

    markets
    |> Enum.filter(&sports_market?/1)
    |> Enum.filter(&has_activity?/1)  # Filter markets with some activity
    |> Enum.filter(&is_tradeable?/1)  # Filter out weird multi-leg markets
    |> Enum.filter(&has_reasonable_price?/1)  # Filter markets with reasonable prices
    |> maybe_filter_sport(sport_filter)
    |> maybe_filter_volume(min_volume)
    |> maybe_filter_settling(settling_hours)
    |> Enum.map(&format_for_analysis/1)
    |> Enum.sort_by(fn m -> {-liquidity_score(m), -volume_score(m), m.close_time} end)
  end

  defp has_activity?(market) do
    # Market has some trading activity (volume, open interest, or liquidity)
    volume = market["volume"] || 0
    open_interest = market["open_interest"] || 0
    liquidity = market["liquidity"] || 0
    volume > 0 || open_interest > 0 || liquidity > 0
  end

  defp is_tradeable?(market) do
    title = String.downcase(market["title"] || "")
    ticker = String.downcase(market["ticker"] || "")

    # Must be a single game market, not a multi-leg parlay
    is_single_game = String.contains?(ticker, "singlegame") ||
                     !String.contains?(ticker, "multigame")

    # Filter out multi-leg parlays (multiple conditions separated by commas)
    comma_count = title |> String.graphemes() |> Enum.count(&(&1 == ","))
    is_not_parlay = comma_count <= 1

    # Filter out player props (stat lines like "Player: 20+")
    is_not_player_prop = !Regex.match?(~r/\d+\+/, title) &&
                         !String.contains?(title, "points scored") &&
                         !String.contains?(title, "d/st")

    # Only keep simple game outcome bets
    is_game_outcome = String.contains?(title, "wins") ||
                      String.contains?(title, "win") ||
                      String.contains?(title, "tie") ||
                      String.contains?(title, "draw") ||
                      String.contains?(title, "over") ||
                      String.contains?(title, "under") ||
                      # Match "Team vs Team" style titles
                      String.contains?(title, " vs ")

    is_single_game && is_not_parlay && is_not_player_prop && is_game_outcome
  end

  defp has_reasonable_price?(market) do
    # Filter out markets where yes_ask is 100 (no sellers) or very high
    # and markets where spread is too wide to be useful
    yes_ask = market["yes_ask"] || 100
    yes_bid = market["yes_bid"] || 0
    no_ask = market["no_ask"] || 100
    no_bid = market["no_bid"] || 0

    # Market should have at least one side with reasonable pricing
    yes_tradeable = yes_ask < 95 || yes_bid > 5
    no_tradeable = no_ask < 95 || no_bid > 5

    yes_tradeable || no_tradeable
  end

  defp liquidity_score(market) do
    # Prioritize markets with tighter spreads and more liquidity
    yes_bid = market.yes_bid || 0
    yes_ask = market.yes_ask || 100
    no_bid = market.no_bid || 0
    no_ask = market.no_ask || 100
    liquidity = market.liquidity || 0

    # Tighter spread = better
    yes_spread = yes_ask - yes_bid
    no_spread = no_ask - no_bid
    min_spread = min(yes_spread, no_spread)

    # Score: liquidity bonus minus spread penalty
    liquidity + max(0, 100 - min_spread)
  end

  defp volume_score(market) do
    (market.volume || 0) + (market.open_interest || 0)
  end

  defp maybe_filter_sport(markets, nil), do: markets
  defp maybe_filter_sport(markets, sport) do
    # Use the categorize_sport function for consistent filtering
    Enum.filter(markets, fn market ->
      categorize_sport(market) == sport
    end)
  end

  defp maybe_filter_volume(markets, nil), do: markets
  defp maybe_filter_volume(markets, min_volume) do
    Enum.filter(markets, fn market ->
      (market["volume"] || 0) >= min_volume
    end)
  end

  defp maybe_filter_settling(markets, nil), do: markets
  defp maybe_filter_settling(markets, hours) do
    now = System.system_time(:second)
    max_close = now + (hours * 3600)

    Enum.filter(markets, fn market ->
      case parse_close_time(market["close_time"] || market["expiration_time"]) do
        nil -> false
        close_ts -> close_ts <= max_close
      end
    end)
  end

  defp parse_close_time(nil), do: nil
  defp parse_close_time(ts) when is_integer(ts), do: ts
  defp parse_close_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end
end
