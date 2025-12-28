defmodule SofiTrader.AI.SportsAnalyzer do
  @moduledoc """
  Analyzes sports markets using AI to identify underpriced bets.

  Takes market data and sends it to ChatGPT for analysis, returning
  a recommendation on whether YES, NO, or neither is underpriced.

  ## Usage

      market = SportsScanner.format_for_analysis(raw_market)
      {:ok, analysis} = SportsAnalyzer.analyze(market)

      # Returns:
      %{
        recommendation: :yes | :no | :skip,
        confidence: 0.0..1.0,
        fair_value: 45,
        current_price: 38,
        edge: 7,
        reasoning: "The Lakers are favored by..."
      }
  """

  require Logger

  alias SofiTrader.AI.OpenAIClient

  @system_prompt """
  You are an elite sports betting analyst specializing in finding mispriced game outcomes. Your edge comes from deep analysis that casual bettors miss.

  ## YOUR ANALYSIS FRAMEWORK

  For each game, systematically evaluate:

  ### 1. RECENT FORM & MOMENTUM (Last 5-10 games)
  - Win/loss streaks and scoring trends
  - Performance trajectory (improving/declining)
  - Margin of victory patterns

  ### 2. HEAD-TO-HEAD HISTORY
  - Historical matchup record between these teams
  - Home/away splits in this specific matchup
  - Recent meetings (last 2-3 seasons)

  ### 3. HOME/AWAY ADVANTAGE
  - Home team's record at home vs away
  - Away team's road performance
  - Travel factors (back-to-back, cross-country)
  - Altitude/weather considerations

  ### 4. INJURIES & ROSTER
  - Star player availability (use your knowledge cutoff)
  - Key position injuries (QB, goalie, point guard)
  - Depth chart impact
  - Players returning from injury

  ### 5. SCHEDULE & REST
  - Days of rest for each team
  - Back-to-back games
  - Quality of recent opponents
  - Playoff/elimination implications

  ### 6. SITUATIONAL FACTORS
  - Motivation levels (playoff race, rivalry, revenge)
  - Coaching matchups and tactical advantages
  - Late-season rest for locked playoff teams
  - Weather (outdoor sports)

  ### 7. MARKET INEFFICIENCY SIGNALS
  - Public bias toward popular teams
  - Overreaction to recent results
  - Undervaluation of underdogs in certain spots

  ## PRICING MECHANICS
  - YES price = implied probability of that outcome
  - If YES costs 40¢, market implies 40% chance
  - Your edge = (Your probability - Market probability)
  - Need 5%+ edge to recommend a bet

  ## DECISION RULES
  - **Recommend YES**: Your estimated probability > YES price + 5%
  - **Recommend NO**: Your estimated probability < (100 - NO price) - 5%
  - **SKIP if**:
    - Insufficient information about teams
    - Game already started or completed
    - Edge is marginal (<5%)
    - High uncertainty (both teams evenly matched with no clear edge)

  ## RESPONSE FORMAT (JSON only, no markdown):
  {
    "recommendation": "YES" | "NO" | "SKIP",
    "confidence": 0.0-1.0,
    "fair_value_yes": <your probability estimate as cents 1-99>,
    "reasoning": "<2-3 sentences with specific factors driving your edge>",
    "key_factors": ["specific factor 1", "specific factor 2", "specific factor 3"]
  }

  BE SPECIFIC in your reasoning - mention team names, player names, specific stats or trends. Generic analysis = SKIP.
  """

  @doc """
  Build the user prompt for analysis.
  """
  def build_user_prompt(title, subtitle, yes_price, no_price, sport, close_time, rules) do
    subtitle_line = if subtitle && subtitle != "", do: "Additional context: #{subtitle}\n", else: ""
    close_line = if close_time, do: "Game time: #{close_time}\n", else: ""
    rules_section = if rules && rules != "", do: "Settlement rules: #{rules}\n", else: ""

    # Parse teams from title to make YES/NO crystal clear
    {yes_team, no_team} = parse_teams_from_title(title)

    sport_context = case sport do
      :nfl -> "NFL/College Football - Consider: QB matchups, home field (3pt avg advantage), weather for outdoor games, divisional rivalry intensity, playoff implications"
      :nba -> "NBA Basketball - Consider: Back-to-back fatigue, home court (3-4pt advantage), star player rest, playoff seeding races, tanking scenarios"
      :nhl -> "NHL Hockey - Consider: Goalie matchups (critical), home ice advantage, travel/schedule, playoff positioning, goalie injury/backup situations"
      :mlb -> "MLB Baseball - Consider: Starting pitcher matchups (most important), bullpen rest, home/road splits, playoff race intensity"
      :soccer -> "Soccer/Football - Consider: Home advantage (significant in soccer), fixture congestion, European competition fatigue, relegation/title race motivation, key player suspensions"
      _ -> "Consider all standard factors: home advantage, recent form, injuries, motivation"
    end

    today = Date.utc_today() |> Calendar.strftime("%B %d, %Y")

    """
    TODAY'S DATE: #{today}

    GAME TO ANALYZE:
    #{title}
    #{subtitle_line}
    SPORT: #{sport |> to_string() |> String.upcase()}
    #{sport_context}

    BETTING OPTIONS:
    - BUY YES = Bet that #{yes_team} WINS (costs #{yes_price}¢, implies #{yes_price}% chance)
    - BUY NO = Bet that #{no_team} WINS (costs #{no_price}¢, implies #{no_price}% chance)
    #{close_line}#{rules_section}
    IMPORTANT: This is a REAL game happening now or very soon. Even if you don't have the absolute latest injury news, you MUST still provide analysis based on:
    - Historical team strength and program quality
    - Typical home/away performance patterns
    - Conference strength and historical matchups
    - General team tendencies and coaching

    Do NOT skip just because you lack real-time data. Use your knowledge of these teams/programs to estimate probabilities.

    TASK: Analyze this matchup and determine which team is more likely to win.

    CRITICAL: Your reasoning MUST match your recommendation!
    - If your analysis favors #{yes_team}, recommend YES
    - If your analysis favors #{no_team}, recommend NO
    - Your fair_value_yes should reflect #{yes_team}'s true win probability

    What is your TRUE probability estimate for #{yes_team} winning? Is there a betting edge?
    """
  end

  # Parse teams from title like "Baltimore at Green Bay Winner?" or "Utah vs San Antonio Winner?"
  defp parse_teams_from_title(title) do
    cond do
      String.contains?(title, " at ") ->
        case Regex.run(~r/(.+?) at (.+?) Winner\??/, title) do
          [_, team_a, team_b] -> {String.trim(team_a), String.trim(team_b)}
          _ -> {title, "the opponent"}
        end
      String.contains?(title, " vs ") ->
        case Regex.run(~r/(.+?) vs (.+?) Winner\??/, title) do
          [_, team_a, team_b] -> {String.trim(team_a), String.trim(team_b)}
          _ -> {title, "the opponent"}
        end
      true ->
        {title, "the opponent"}
    end
  end

  @doc """
  Analyze a single market for mispricing.

  ## Options
    - `:model` - Model to use (default: "o4-mini" for reasoning)
      - "o4-mini" - Good reasoning model
      - "o3" - Advanced reasoning model
      - "gpt-4o" - Standard model, fastest
    - `:deep` - Use more thorough analysis with higher token limit

  ## Returns
    - `{:ok, analysis}` - Analysis result map
    - `{:error, reason}` - If analysis fails
  """
  def analyze(market, opts \\ []) do
    # Use o4-mini for good reasoning on sports analysis
    model = Keyword.get(opts, :model, "o4-mini")

    prompt = build_prompt(market)

    Logger.info("[SportsAnalyzer] Analyzing: #{market.title} with #{model}")

    # o-series models don't use temperature parameter
    case OpenAIClient.chat(prompt,
           system: @system_prompt,
           model: model,
           max_tokens: 2000   # Allow detailed reasoning
         ) do
      {:ok, response} ->
        parse_response(response, market)

      {:error, reason} ->
        Logger.error("[SportsAnalyzer] Analysis failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Analyze multiple markets and return only actionable opportunities.

  ## Options
    - `:min_confidence` - Minimum confidence threshold (default: 0.6)
    - `:min_edge` - Minimum edge in cents (default: 5)
    - `:model` - GPT model to use
  """
  def analyze_batch(markets, opts \\ []) do
    min_confidence = Keyword.get(opts, :min_confidence, 0.6)
    min_edge = Keyword.get(opts, :min_edge, 5)

    results =
      markets
      |> Enum.map(fn market ->
        case analyze(market, opts) do
          {:ok, analysis} -> {market, analysis}
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn {_market, analysis} ->
        analysis.recommendation != :skip &&
        analysis.confidence >= min_confidence &&
        analysis.edge >= min_edge
      end)
      |> Enum.sort_by(fn {_market, analysis} -> -analysis.edge end)

    {:ok, results}
  end

  @doc """
  Build the analysis prompt for a market.
  """
  def build_prompt(market) do
    # Use ASK prices (what you'd pay to buy) not BID prices
    yes_price = market.best_yes_price || market.yes_ask || 50
    no_price = market.best_no_price || market.no_ask || 50

    rules = cond do
      market.rules_primary && market.rules_secondary ->
        "#{market.rules_primary}\n#{market.rules_secondary}"
      market.rules_primary ->
        market.rules_primary
      true ->
        nil
    end

    build_user_prompt(
      market.title,
      market.subtitle,
      yes_price,
      no_price,
      market.sport,
      format_close_time(market.close_time),
      rules
    )
  end

  # Private functions

  defp parse_response(response, market) do
    # Try to extract JSON from the response
    json_str = extract_json(response)

    case Jason.decode(json_str) do
      {:ok, parsed} ->
        # Use ASK price (what you'd pay to buy)
        yes_price = market.best_yes_price || market.yes_ask || 50
        no_price = market.best_no_price || market.no_ask || 50
        fair_value = parsed["fair_value_yes"] || 50

        # Edge = fair value - price you'd pay
        edge = case parsed["recommendation"] do
          "YES" -> fair_value - yes_price
          "NO" -> (100 - fair_value) - no_price
          _ -> 0
        end

        analysis = %{
          recommendation: parse_recommendation(parsed["recommendation"]),
          confidence: parsed["confidence"] || 0.5,
          fair_value_yes: fair_value,
          current_yes_price: yes_price,
          current_no_price: no_price,
          edge: max(0, edge),  # Edge can't be negative for a recommended bet
          reasoning: parsed["reasoning"] || "",
          key_factors: parsed["key_factors"] || [],
          raw_response: response
        }

        {:ok, analysis}

      {:error, _} ->
        Logger.warning("[SportsAnalyzer] Failed to parse JSON response: #{response}")
        {:error, :parse_failed}
    end
  end

  defp extract_json(response) do
    # Try to find JSON in the response (might be wrapped in markdown code blocks)
    cond do
      String.contains?(response, "```json") ->
        response
        |> String.split("```json")
        |> List.last()
        |> String.split("```")
        |> List.first()
        |> String.trim()

      String.contains?(response, "```") ->
        response
        |> String.split("```")
        |> Enum.at(1, response)
        |> String.trim()

      String.starts_with?(String.trim(response), "{") ->
        String.trim(response)

      true ->
        response
    end
  end

  defp parse_recommendation("YES"), do: :yes
  defp parse_recommendation("NO"), do: :no
  defp parse_recommendation(_), do: :skip

  defp format_close_time(nil), do: nil
  defp format_close_time(ts) when is_binary(ts), do: ts
  defp format_close_time(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> nil
    end
  end
end
