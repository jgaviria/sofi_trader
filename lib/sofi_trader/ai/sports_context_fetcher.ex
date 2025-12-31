defmodule SofiTrader.AI.SportsContextFetcher do
  @moduledoc """
  Fetches real-time context about sports matches using web search.

  Before AI analysis, this module searches for:
  - Current tournament standings and qualification status
  - Team news and injury reports
  - Recent form and head-to-head
  - Match importance and stakes

  This provides the AI with accurate, up-to-date information rather than
  relying on potentially outdated training data.
  """

  require Logger

  @search_timeout 15_000  # 15 seconds for search
  @summarize_timeout 30_000  # 30 seconds for summarization

  @doc """
  Fetch current context for a match.

  Returns a map with:
  - :tournament_context - Current standings, qualification status
  - :team_a_context - News, form, injuries for first team
  - :team_b_context - News, form, injuries for second team
  - :match_context - Preview, importance, stakes
  """
  def fetch_match_context(team_a, team_b, sport, opts \\ []) do
    Logger.info("[SportsContextFetcher] Fetching context for #{team_a} vs #{team_b} (#{sport})")

    # Build search queries based on the match
    queries = build_search_queries(team_a, team_b, sport)

    # Fetch context in parallel
    tasks = [
      Task.async(fn -> search_and_summarize(queries.tournament, "tournament standings and qualification status") end),
      Task.async(fn -> search_and_summarize(queries.match_preview, "match preview and importance") end),
      Task.async(fn -> search_and_summarize(queries.team_a_news, "#{team_a} recent news and form") end),
      Task.async(fn -> search_and_summarize(queries.team_b_news, "#{team_b} recent news and form") end)
    ]

    # Collect results with timeout
    timeout = Keyword.get(opts, :timeout, @summarize_timeout)
    results = tasks
    |> Enum.map(fn task ->
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end
    end)

    [tournament_result, match_result, team_a_result, team_b_result] = results

    context = %{
      tournament_context: unwrap_result(tournament_result, "No tournament context available"),
      match_context: unwrap_result(match_result, "No match preview available"),
      team_a_context: unwrap_result(team_a_result, "No recent news for #{team_a}"),
      team_b_context: unwrap_result(team_b_result, "No recent news for #{team_b}"),
      fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, context}
  rescue
    e ->
      Logger.error("[SportsContextFetcher] Error fetching context: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Format context for inclusion in AI prompt.
  """
  def format_context_for_prompt(context) when is_map(context) do
    """
    ## REAL-TIME CONTEXT (Fetched #{context.fetched_at})

    ### TOURNAMENT STATUS
    #{context.tournament_context}

    ### MATCH PREVIEW
    #{context.match_context}

    ### TEAM 1 NEWS
    #{context.team_a_context}

    ### TEAM 2 NEWS
    #{context.team_b_context}

    ---
    IMPORTANT: Use this real-time context to inform your analysis. The above information
    supersedes any conflicting knowledge from your training data.
    """
  end
  def format_context_for_prompt(_), do: ""

  # Build search queries based on sport and teams
  defp build_search_queries(team_a, team_b, sport) do
    today = Date.utc_today() |> Calendar.strftime("%B %Y")

    base_match = "#{team_a} vs #{team_b}"

    tournament_query = case sport do
      :soccer ->
        # Try to identify the competition
        cond do
          afcon_team?(team_a) || afcon_team?(team_b) ->
            "AFCON 2025 #{today} standings group stage #{team_a} #{team_b} qualified eliminated"
          premier_league_team?(team_a) || premier_league_team?(team_b) ->
            "Premier League standings #{today} #{team_a} #{team_b}"
          true ->
            "#{base_match} #{today} tournament standings qualification"
        end
      :nfl -> "NFL standings #{today} playoff picture #{team_a} #{team_b}"
      :nba -> "NBA standings #{today} playoff race #{team_a} #{team_b}"
      :nhl -> "NHL standings #{today} #{team_a} #{team_b}"
      :mlb -> "MLB standings #{today} #{team_a} #{team_b}"
      _ -> "#{base_match} #{today} standings"
    end

    %{
      tournament: tournament_query,
      match_preview: "#{base_match} preview #{today} lineup news",
      team_a_news: "#{team_a} news form injuries #{today}",
      team_b_news: "#{team_b} news form injuries #{today}"
    }
  end

  # AFCON participating teams (2025)
  defp afcon_team?(team) do
    afcon_teams = [
      "algeria", "equatorial guinea", "burkina faso", "sudan", "angola", "cameroon",
      "cape verde", "cote d'ivoire", "ivory coast", "dr congo", "congo", "egypt",
      "gabon", "gambia", "ghana", "guinea", "guinea-bissau", "mali", "mauritania",
      "morocco", "mozambique", "namibia", "nigeria", "senegal", "sierra leone",
      "south africa", "tanzania", "tunisia", "uganda", "zambia", "zimbabwe", "benin",
      "botswana", "comoros"
    ]
    String.downcase(team) in afcon_teams
  end

  # English Premier League teams
  defp premier_league_team?(team) do
    epl_teams = [
      "arsenal", "aston villa", "bournemouth", "brentford", "brighton", "chelsea",
      "crystal palace", "everton", "fulham", "ipswich", "leicester", "liverpool",
      "manchester city", "manchester united", "newcastle", "nottingham forest",
      "southampton", "tottenham", "west ham", "wolverhampton", "wolves"
    ]
    String.downcase(team) in epl_teams
  end

  # Search the web and summarize results
  defp search_and_summarize(query, focus) do
    Logger.info("[SportsContextFetcher] Searching: #{query}")

    # Use Req to call a search API or web search
    # For now, we'll use DuckDuckGo's HTML search
    case search_web(query) do
      {:ok, search_results} ->
        summarize_results(search_results, focus)

      {:error, reason} ->
        Logger.warning("[SportsContextFetcher] Search failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Perform web search using DuckDuckGo HTML
  defp search_web(query) do
    encoded_query = URI.encode(query)
    url = "https://html.duckduckgo.com/html/?q=#{encoded_query}"

    headers = [
      {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
    ]

    case Req.get(url, headers: headers, receive_timeout: @search_timeout) do
      {:ok, %{status: 200, body: body}} ->
        # Extract snippets from DuckDuckGo HTML results
        snippets = extract_ddg_snippets(body)
        {:ok, snippets}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extract text snippets from DuckDuckGo HTML results
  defp extract_ddg_snippets(html) do
    # Simple regex extraction for result snippets
    # DuckDuckGo uses class="result__snippet" for snippets
    snippet_regex = ~r/<a class="result__snippet"[^>]*>([^<]+)<\/a>/
    title_regex = ~r/<a class="result__a"[^>]*>([^<]+)<\/a>/

    snippets = Regex.scan(snippet_regex, html)
    |> Enum.map(fn [_, snippet] -> decode_html_entities(snippet) end)
    |> Enum.take(5)

    titles = Regex.scan(title_regex, html)
    |> Enum.map(fn [_, title] -> decode_html_entities(title) end)
    |> Enum.take(5)

    # Combine titles and snippets
    Enum.zip(titles, snippets)
    |> Enum.map(fn {title, snippet} -> "#{title}: #{snippet}" end)
    |> Enum.join("\n\n")
  end

  # Simple HTML entity decoder
  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
    |> decode_numeric_entities()
  end

  defp decode_numeric_entities(text) do
    Regex.replace(~r/&#(\d+);/, text, fn _, code ->
      try do
        <<String.to_integer(code)::utf8>>
      rescue
        _ -> ""
      end
    end)
  end

  # Summarize search results using the AI
  defp summarize_results(search_results, _focus) when search_results == "" or is_nil(search_results) do
    {:ok, "No relevant information found."}
  end

  defp summarize_results(search_results, focus) do
    prompt = """
    Based on these search results, extract ONLY the factual information about: #{focus}

    Search Results:
    #{search_results}

    Instructions:
    - Extract ONLY facts (standings, scores, dates, injury status, qualification status)
    - Do NOT add opinions or predictions
    - If teams have qualified/been eliminated, STATE THIS CLEARLY
    - If no relevant info found, say "No specific information found"
    - Keep response under 150 words
    - Use bullet points for clarity
    """

    # Use a fast model for summarization
    case SofiTrader.AI.OpenAIClient.chat(prompt,
           model: "gpt-4o-mini",
           max_tokens: 300,
           temperature: 0.3
         ) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap_result({:ok, content}, _default), do: content
  defp unwrap_result({:error, _}, default), do: default
  defp unwrap_result(_, default), do: default
end
