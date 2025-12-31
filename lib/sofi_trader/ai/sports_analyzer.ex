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

  # Base system prompt - used for all sports
  @base_system_prompt """
  You are an ELITE sports betting analyst and handicapper with decades of experience finding VALUE in betting markets. You specialize in identifying MISPRICED outcomes that casual bettors and even sharp money overlooks.

  YOUR MISSION: Find edges where the market price DOES NOT reflect the true probability of an outcome.

  ## CORE ANALYSIS PRINCIPLES

  ### 1. CONTRARIAN THINKING
  - Question the obvious narrative. If everyone loves a team, ask WHY the line isn't higher.
  - Look for "trap games" where public perception diverges from reality.
  - Identify when sharp money might be fading public sentiment.

  ### 2. SITUATIONAL HANDICAPPING
  - Motivation is EVERYTHING. A team with nothing to play for vs desperate opponent = fade.
  - Revenge games, rivalry games, statement games - these matter.
  - Teams coming off emotional wins often have letdowns.
  - Teams coming off bad losses often bounce back with intensity.

  ### 3. LINE VALUE ANALYSIS
  - Compare the implied probability to your calculated probability.
  - A 5%+ edge is significant. A 10%+ edge is a strong play.
  - Consider: "Would I bet this at a worse price?" If yes, there's value.

  ### 4. PUBLIC VS SHARP MONEY
  - Heavy public action on favorites often creates value on underdogs.
  - When the line moves opposite to public sentiment, sharp money is involved.
  - Trendy teams get overbet; unglamorous teams get underbet.

  ### 5. RECENCY BIAS EXPLOITATION
  - Markets overreact to recent results (last 1-2 games).
  - A team that lost badly last week might be undervalued.
  - A team on a hot streak might be overvalued.

  ## RESPONSE FORMAT (JSON only, no markdown):
  {
    "recommendation": "YES" | "NO" | "SKIP",
    "confidence": 0.0-1.0,
    "fair_value_yes": <your probability estimate as cents 1-99>,
    "reasoning": "<2-3 sentences with SPECIFIC factors driving your edge>",
    "key_factors": ["specific factor 1", "specific factor 2", "specific factor 3"]
  }

  BE SPECIFIC - mention team names, player names, specific situations. Generic analysis = SKIP.
  """

  # Soccer-specific system prompt
  @soccer_system_prompt """
  You are an ELITE soccer/football betting analyst specializing in finding VALUE in match outcome markets. You have deep knowledge of global leagues, tournaments, and the unique dynamics of soccer betting.

  ## SOCCER-SPECIFIC ANALYSIS FRAMEWORK

  ### 1. THE DRAW - SOCCER'S UNIQUE EDGE
  ⚠️ CRITICAL: In soccer, DRAWS happen 25-30% of the time on average. This is HUGE for finding value.
  - Low-scoring matches (defensive teams, bad weather) = higher draw probability
  - Evenly matched teams = draw probability often UNDERPRICED
  - Teams happy with a point (already qualified, avoiding relegation) = draw more likely
  - Derby matches and rivalry games often end in draws (cautious play)
  - Cup/tournament knockout stages have LOWER draw rates (must-win mentality)
  - Group stage final matchdays: teams may "agree" to a draw that benefits both

  ### 2. TOURNAMENT & COMPETITION CONTEXT
  - **Group Stage Dynamics**: Has a team already qualified? They WILL rest players.
  - **Dead Rubber Games**: If a team can't advance or is already through, motivation plummets.
  - **Coefficient/Prize Money**: Some teams need wins for UEFA coefficient or prize pools.
  - **Relegation Six-Pointers**: Teams fighting relegation play with desperate intensity.
  - **Title Race**: Teams chasing titles play differently than mid-table teams.
  - **Cup vs League**: Teams often prioritize one competition over another.

  ### 3. HOME ADVANTAGE IN SOCCER (MASSIVE)
  - Home advantage in soccer is worth approximately 0.4-0.5 goals.
  - Some stadiums are FORTRESSES (Anfield, Signal Iduna Park, Maracanã).
  - Altitude matters: La Paz, Mexico City, Quito = huge home edge.
  - Fan atmosphere: Full stadiums vs empty = different energy.
  - Travel fatigue: European teams traveling to Kazakhstan, Israel = disadvantage.

  ### 4. SQUAD ROTATION & FIXTURE CONGESTION
  - Champions League weeks: Premier League teams often rotate for midweek European games.
  - 3 games in 7 days = fatigue, rotation, B-team lineups.
  - International breaks: Players return tired, injured, or mentally checked out.
  - End of season: Some teams have 15+ games in 2 months.

  ### 5. TACTICAL & STYLE MATCHUPS
  - High-pressing teams struggle against low-block defensive sides.
  - Teams that dominate possession can struggle vs counter-attacking opponents.
  - Set-piece specialists vs teams weak defending corners/free kicks.
  - Managers with specific tactical advantages against certain opponents.

  ### 6. KEY PLAYER IMPACT IN SOCCER
  - Unlike team sports, ONE player can dominate (Haaland, Mbappé, Vinicius).
  - Goalkeeper form is crucial - a hot keeper can steal games.
  - Central midfield control often decides matches.
  - Suspensions of key defenders = vulnerability to specific attackers.

  ### 7. WEATHER & PITCH CONDITIONS
  - Rain = fewer goals, more unpredictable outcomes, favors underdogs.
  - Extreme heat = pace of game slows, fitness matters more.
  - Poor pitch conditions = technical teams struggle.
  - Wind = long balls more effective, crossing game affected.

  ### 8. PUBLIC BETTING BIASES IN SOCCER
  - Casual bettors overbet on: Big clubs (Man United, Real Madrid, Barcelona)
  - Casual bettors underbet on: Lower-profile leagues, defensive teams, draws
  - Recent Champions League/World Cup narrative overly influences prices.

  ### 9. CURRENT FORM & MOMENTUM
  - Last 5 home/away results (not just overall)
  - Goals scored AND conceded trends
  - xG (expected goals) vs actual goals - regression coming?
  - Winning streak teams often due for regression

  ### 10. MARKET SENTIMENT & CHATTER
  - What are fans saying? Social media can reveal lineup leaks, injury updates.
  - Betting market movements - are sharps on one side?
  - Manager quotes - are they downplaying expectations?

  ## DECISION RULES
  - **Recommend YES**: Your probability for YES team winning > YES price + 5%
  - **Recommend NO**: Your probability for NO team winning > NO price + 5%
  - **Consider the DRAW**: If draw probability is high, both YES and NO might be bad bets
  - **SKIP if**: Draw is most likely outcome OR edge is marginal (<5%)

  ## RESPONSE FORMAT (JSON only, no markdown):
  {
    "recommendation": "YES" | "NO" | "SKIP",
    "confidence": 0.0-1.0,
    "fair_value_yes": <your probability estimate for YES team winning, 1-99>,
    "draw_probability": <your estimate of draw probability, 1-99>,
    "reasoning": "<2-3 sentences with SPECIFIC factors - team names, player names, tournament context>",
    "key_factors": ["factor 1", "factor 2", "factor 3"]
  }
  """

  # NFL-specific system prompt
  @nfl_system_prompt """
  You are an ELITE NFL betting analyst and handicapper. You specialize in finding VALUE by analyzing matchups, situations, and market inefficiencies that casual bettors miss.

  ## NFL-SPECIFIC ANALYSIS FRAMEWORK

  ### 1. QUARTERBACK IS KING
  - QB matchup is 70% of NFL handicapping. Elite QBs can overcome bad situations.
  - Backup QBs = massive downgrade. Even experienced backups lose ~7 points of value.
  - Young QBs in hostile road environments struggle.
  - QBs facing their former teams often have revenge games.

  ### 2. HOME FIELD ADVANTAGE (VARIES WILDLY)
  - Average HFA in NFL is ~2.5-3 points.
  - Some stadiums are worth more: Seattle (12th Man), Arrowhead, Lambeau in winter.
  - Dome teams traveling to cold weather = significant disadvantage.
  - West Coast teams playing 1 PM ET games = "body clock" disadvantage.

  ### 3. SCHEDULE SPOTS & SITUATIONAL ANGLES
  - **Trap Games**: Team plays down to opponent after big win or before big game.
  - **Revenge Games**: Players/coaches vs former team often outperform.
  - **Short Rest**: Thursday games after Sunday = favors home team.
  - **Bye Weeks**: Teams off bye are rested but sometimes rusty.
  - **Playoff Positioning**: Week 17-18, teams resting starters if locked in.
  - **Elimination Games**: Teams facing "win or go home" play with desperation.

  ### 4. OFFENSIVE/DEFENSIVE MATCHUPS
  - Elite pass rush vs bad offensive line = sack fest, turnovers.
  - Run-heavy team vs run-stuffing defense = game script changes.
  - Speed receivers vs slow linebackers = mismatch exploitation.
  - Check injury reports for O-line - losing a LT is massive.

  ### 5. WEATHER IMPACT
  - Wind 15+ mph = passing game struggles, unders, running teams favored.
  - Rain/snow = turnovers, lower scoring, unpredictable.
  - Extreme cold favors physical, run-first teams.
  - Dome teams in outdoor elements = at disadvantage.

  ### 6. PUBLIC BETTING BIASES
  - Public loves: Cowboys, Patriots (legacy), Packers, popular teams.
  - Public overreacts to prime-time performances (Monday Night).
  - "Sexy" offenses get overbet; grinding defensive teams underbet.
  - Teams coming off blowout wins are overvalued.

  ### 7. COACHING MATTERS
  - Elite coaches cover spreads at higher rates (Belichick, Reid, Shanahan).
  - First-year coaches often struggle early, improve late.
  - Conservative coaches won't take risks in close games.
  - Aggressive 4th-down coaches change expected outcomes.

  ### 8. DIVISIONAL GAMES
  - Division rivals know each other = games are tighter.
  - Underdogs cover more in divisional matchups.
  - Season sweeps are rare - split outcomes are common.

  ## RESPONSE FORMAT (JSON only, no markdown):
  {
    "recommendation": "YES" | "NO" | "SKIP",
    "confidence": 0.0-1.0,
    "fair_value_yes": <probability estimate 1-99>,
    "reasoning": "<2-3 sentences with SPECIFIC factors>",
    "key_factors": ["factor 1", "factor 2", "factor 3"]
  }
  """

  # NBA-specific system prompt
  @nba_system_prompt """
  You are an ELITE NBA betting analyst specializing in finding VALUE in game outcome markets.

  ## NBA-SPECIFIC ANALYSIS FRAMEWORK

  ### 1. REST & SCHEDULE (MOST IMPORTANT IN NBA)
  - **Back-to-Backs**: Team on B2B vs rested opponent = 3-5 point disadvantage.
  - **3-in-4 nights**: Fatigue compounds. Check previous game locations.
  - **Rest Advantage**: 2+ days rest vs B2B = significant edge.
  - **Travel**: Cross-country flights + time zones = sluggish starts.
  - **Altitude**: Denver at home is a massive advantage (5,280 ft).

  ### 2. LOAD MANAGEMENT & INJURIES
  - Stars sit B2Bs more than ever. Check injury reports close to tip.
  - Old stars (LeBron, Curry, Durant) get strategic rest.
  - Even "probable" players sometimes sit last minute.
  - Depth matters less than star power - NBA is star-driven.

  ### 3. MOTIVATION FACTORS
  - **Playoff Seeding**: Teams fighting for position play hard.
  - **Tanking**: Teams out of playoffs often rest players, lose on purpose.
  - **Revenge Games**: Players vs former teams almost always bring extra effort.
  - **National TV**: Stars show up for TNT/ESPN games.
  - **Statement Games**: Young teams want to prove themselves vs contenders.

  ### 4. HOME COURT ADVANTAGE
  - NBA HCA is worth ~3-4 points on average.
  - Some arenas are tougher: MSG, United Center, Crypto.com Arena.
  - Crowd energy matters - playoff atmospheres in regular season are rare.

  ### 5. STYLE MATCHUPS
  - Pace matters: Fast teams want to run, slow teams want to grind.
  - Elite defenses can slow down high-scoring offenses.
  - Teams with dominant big men struggle vs small-ball pace.
  - 3-point shooting variance: hot/cold nights swing outcomes.

  ### 6. PUBLIC BETTING BIASES
  - Public loves: Lakers, Knicks, Warriors, Celtics, big-market teams.
  - Public overvalues regular season records early in season.
  - Teams on winning streaks get overbet.
  - "Ugly" defensive teams are undervalued.

  ### 7. END OF SEASON DYNAMICS
  - Last 2 weeks: massive lineup changes, tanking, resting.
  - Play-in tournament: huge motivation for 7-10 seeds.
  - Teams locked into playoff spots often coast.

  ## RESPONSE FORMAT (JSON only, no markdown):
  {
    "recommendation": "YES" | "NO" | "SKIP",
    "confidence": 0.0-1.0,
    "fair_value_yes": <probability estimate 1-99>,
    "reasoning": "<2-3 sentences with SPECIFIC factors>",
    "key_factors": ["factor 1", "factor 2", "factor 3"]
  }
  """

  # NHL-specific system prompt
  @nhl_system_prompt """
  You are an ELITE NHL betting analyst specializing in hockey betting markets.

  ## NHL-SPECIFIC ANALYSIS FRAMEWORK

  ### 1. GOALTENDING IS EVERYTHING
  - Goalie matchup is 50%+ of NHL handicapping.
  - Elite goalies (Vasilevskiy, Shesterkin, Demko) can steal any game.
  - Backup goalies = significant downgrade, often 10+ save % difference.
  - Goalies on B2B almost never start - check for backup starts.
  - Hot goalies can carry mediocre teams; cold goalies sink good teams.

  ### 2. SCHEDULE & FATIGUE
  - **Back-to-Backs**: Huge in hockey. Goalies rarely play both.
  - **Travel**: West Coast to East Coast = jet lag, slow starts.
  - **3-in-4**: Third game is often a loss, especially road teams.
  - **Rest Days**: 2+ days rest vs tired opponent = significant edge.

  ### 3. HOME ICE ADVANTAGE
  - NHL HCA is significant (~54% home win rate).
  - Last change at home = tactical advantage.
  - Some buildings are tough: MSG, United Center, Rogers Arena.
  - Altitude: Denver's Altitude affects visiting teams.

  ### 4. SPECIAL TEAMS
  - Power play and penalty kill can decide games.
  - Disciplined teams vs undisciplined = PP opportunities.
  - Teams with elite PP (25%+) are dangerous when trailing.
  - PK struggles = vulnerability in tight games.

  ### 5. DIVISIONAL GAMES
  - Division rivals play 4+ times per season - know each other well.
  - Games are typically tighter, lower scoring.
  - Playoff implications make late-season divisional games intense.

  ### 6. INJURIES BEYOND GOALIE
  - Top-line centers are crucial (faceoffs, both ends).
  - Top-pair defensemen anchor the team.
  - Depth matters in hockey - 4th line can contribute.

  ### 7. PUBLIC BETTING BIASES
  - Public loves: Original Six teams, flashy offensive teams.
  - Public undervalues: Defensive teams, small-market clubs.
  - Teams on hot streaks get overbet.

  ### 8. PLAYOFF RACE DYNAMICS
  - Bubble teams play desperate hockey.
  - Teams locked in often rest players late.
  - Wild card races = intensity.

  ## RESPONSE FORMAT (JSON only, no markdown):
  {
    "recommendation": "YES" | "NO" | "SKIP",
    "confidence": 0.0-1.0,
    "fair_value_yes": <probability estimate 1-99>,
    "reasoning": "<2-3 sentences with SPECIFIC factors>",
    "key_factors": ["factor 1", "factor 2", "factor 3"]
  }
  """

  # MLB-specific system prompt
  @mlb_system_prompt """
  You are an ELITE MLB betting analyst specializing in baseball betting markets.

  ## MLB-SPECIFIC ANALYSIS FRAMEWORK

  ### 1. STARTING PITCHING IS KING (60%+ of handicapping)
  - SP matchup determines the game. Aces vs #5 starters = massive edge.
  - Check recent starts: IP, ERA, WHIP, K rate, HR allowed.
  - Pitchers vs specific lineups - some hitters own certain pitchers.
  - Lefty vs righty splits matter for both pitcher and lineup.
  - Pitch counts: Coming off high-pitch games = shorter outings.

  ### 2. BULLPEN STATE
  - Check bullpen usage last 3 days. Overworked = vulnerable.
  - Elite closers (rare) vs shaky bullpens = late-inning swings.
  - Day games after night games = tired relievers.

  ### 3. HOME/AWAY & BALLPARK FACTORS
  - Some parks favor hitters (Coors, Great American, Fenway).
  - Some parks favor pitchers (Petco, Oracle, Dodger Stadium).
  - Altitude at Coors Field = extra base hits, HR.
  - Turf vs grass can affect ground ball pitchers.

  ### 4. WEATHER
  - Wind blowing out = more runs, favors hitters.
  - Wind blowing in = pitchers' duel.
  - Heat = ball carries further.
  - Humidity = ball doesn't carry as well (myth partially).

  ### 5. TRAVEL & REST
  - Cross-country travel = jet lag, especially for day games.
  - Teams ending road trips often sluggish.
  - Long homestands = comfortable, well-rested.

  ### 6. LINEUP CONSTRUCTION
  - Check if stars are in lineup (rest days common in MLB).
  - Platoon players: Some only play vs LHP or RHP.
  - Catcher matters: Elite framers help pitchers get calls.

  ### 7. PUBLIC BETTING BIASES
  - Public loves: Yankees, Dodgers, big-market teams.
  - Public overvalues wins-losses, ignores underlying stats.
  - Aces get overbet; #4-5 starters can provide value.

  ### 8. SEASON CONTEXT
  - September callups change rosters.
  - Playoff races = intensity.
  - Teams out of it = audition mode for young players.

  ## RESPONSE FORMAT (JSON only, no markdown):
  {
    "recommendation": "YES" | "NO" | "SKIP",
    "confidence": 0.0-1.0,
    "fair_value_yes": <probability estimate 1-99>,
    "reasoning": "<2-3 sentences with SPECIFIC factors>",
    "key_factors": ["factor 1", "factor 2", "factor 3"]
  }
  """

  @doc """
  Get the appropriate system prompt for a sport.
  """
  def get_system_prompt(:soccer), do: @soccer_system_prompt
  def get_system_prompt(:nfl), do: @nfl_system_prompt
  def get_system_prompt(:nba), do: @nba_system_prompt
  def get_system_prompt(:nhl), do: @nhl_system_prompt
  def get_system_prompt(:mlb), do: @mlb_system_prompt
  def get_system_prompt(_), do: @base_system_prompt

  @doc """
  Build the user prompt for analysis.
  """
  def build_user_prompt(title, subtitle, yes_price, no_price, sport, close_time, rules) do
    subtitle_line = if subtitle && subtitle != "", do: "Additional context: #{subtitle}\n", else: ""
    close_line = if close_time, do: "Game time: #{close_time}\n", else: ""
    rules_section = if rules && rules != "", do: "Settlement rules: #{rules}\n", else: ""

    # Parse teams from title to make YES/NO crystal clear
    {yes_team, no_team} = parse_teams_from_title(title)

    today = Date.utc_today() |> Calendar.strftime("%B %d, %Y")

    # Build sport-specific user prompt
    case sport do
      :soccer -> build_soccer_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today)
      :nfl -> build_nfl_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today)
      :nba -> build_nba_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today)
      :nhl -> build_nhl_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today)
      :mlb -> build_mlb_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today)
      _ -> build_generic_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today, sport)
    end
  end

  # Soccer-specific prompt with draw analysis
  defp build_soccer_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today) do
    """
    TODAY'S DATE: #{today}

    ⚽ SOCCER MATCH TO ANALYZE:
    #{title}
    #{subtitle_line}
    #{close_line}#{rules_section}

    CURRENT MARKET PRICES:
    - #{yes_team} to WIN: #{yes_price}¢ (implies #{yes_price}% probability)
    - #{no_team} to WIN: #{no_price}¢ (implies #{no_price}% probability)
    - Implied DRAW probability: #{max(0, 100 - yes_price - no_price)}%

    YOUR TASK - ANALYZE ALL THREE OUTCOMES:

    1. **#{yes_team} WIN PROBABILITY**: What is the TRUE probability #{yes_team} wins outright?

    2. **#{no_team} WIN PROBABILITY**: What is the TRUE probability #{no_team} wins outright?

    3. **DRAW PROBABILITY**: What is the TRUE probability this match ends in a draw?
       Consider: Are both teams defensive? Is either team happy with a point? Tournament context?

    CRITICAL ANALYSIS POINTS FOR THIS MATCH:
    - What competition is this? (League, Cup, Champions League, World Cup, etc.)
    - What's at stake? (Title race, relegation, qualification, dead rubber?)
    - Has either team ALREADY QUALIFIED for something? (They may rest players!)
    - Is either team ELIMINATED? (Motivation drops significantly)
    - Home/Away dynamics - how strong is the home advantage here?
    - Recent form - but watch for regression to mean
    - Key injuries/suspensions you're aware of
    - Head-to-head history
    - Tactical matchup - does one team's style counter the other?

    LOOK FOR VALUE:
    - Is #{yes_team} UNDERPRICED as an underdog? (Public fading them unfairly?)
    - Is #{no_team} UNDERPRICED? (Market overrating #{yes_team}?)
    - Is the DRAW being ignored? (Evenly matched teams, low-scoring potential?)

    RECOMMENDATION RULES:
    - Recommend YES only if #{yes_team}'s true win probability > #{yes_price}% + 5%
    - Recommend NO only if #{no_team}'s true win probability > #{no_price}% + 5%
    - If DRAW is most likely, recommend SKIP (we can't bet on draws in this market)
    - SKIP if no clear edge exists

    Your reasoning MUST match your recommendation. Be SPECIFIC with team names and factors.
    """
  end

  # NFL-specific prompt
  defp build_nfl_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today) do
    """
    TODAY'S DATE: #{today}

    🏈 NFL/COLLEGE FOOTBALL GAME TO ANALYZE:
    #{title}
    #{subtitle_line}
    #{close_line}#{rules_section}

    CURRENT MARKET PRICES:
    - #{yes_team} to WIN: #{yes_price}¢ (implies #{yes_price}% probability)
    - #{no_team} to WIN: #{no_price}¢ (implies #{no_price}% probability)

    YOUR TASK - FIND THE EDGE:

    CRITICAL ANALYSIS POINTS:
    1. **QUARTERBACK SITUATION**: Who's starting? Injury status? Backup scenario?
    2. **HOME/AWAY**: Who has home field? Is it a dome team in cold weather?
    3. **SCHEDULE SPOT**: Trap game? Revenge game? Coming off bye? Short week?
    4. **DIVISIONAL?**: Division rivals play tighter games.
    5. **PLAYOFF IMPLICATIONS**: Fighting for seeding? Locked in and resting? Eliminated?
    6. **WEATHER**: Any extreme weather that affects the game?
    7. **INJURIES**: Key players out? O-line issues?
    8. **COACHING**: Any tactical advantages? Conservative vs aggressive?
    9. **PUBLIC PERCEPTION**: Is the public overreacting to last week's result?

    LOOK FOR VALUE:
    - Is #{yes_team} being OVERVALUED because they're a public favorite?
    - Is #{no_team} being UNDERVALUED as a solid underdog?
    - Is there a SITUATIONAL EDGE the market is missing?

    CONTRARIAN CHECK:
    - If everyone likes #{yes_team}, why isn't the price higher?
    - What does sharp money think? Would they fade the public here?

    RECOMMENDATION:
    - Recommend YES if #{yes_team}'s true win probability > #{yes_price}% + 5%
    - Recommend NO if #{no_team}'s true win probability > #{no_price}% + 5%
    - SKIP if the edge is marginal or uncertain

    Your reasoning MUST match your recommendation. Be SPECIFIC.
    """
  end

  # NBA-specific prompt
  defp build_nba_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today) do
    """
    TODAY'S DATE: #{today}

    🏀 NBA/COLLEGE BASKETBALL GAME TO ANALYZE:
    #{title}
    #{subtitle_line}
    #{close_line}#{rules_section}

    CURRENT MARKET PRICES:
    - #{yes_team} to WIN: #{yes_price}¢ (implies #{yes_price}% probability)
    - #{no_team} to WIN: #{no_price}¢ (implies #{no_price}% probability)

    YOUR TASK - FIND THE EDGE:

    CRITICAL ANALYSIS POINTS:
    1. **REST & SCHEDULE**: Back-to-back? 3-in-4? Travel from where?
    2. **INJURIES/LOAD MANAGEMENT**: Are stars playing? Check injury reports!
    3. **HOME COURT**: How significant is home court for these teams?
    4. **MOTIVATION**: Playoff race? Tanking? Revenge game? National TV?
    5. **MATCHUP STYLES**: Pace of play? Defensive strengths vs offensive weaknesses?
    6. **RECENT FORM**: Hot streak or cold? Due for regression?
    7. **ALTITUDE**: Playing in Denver? That matters.

    LOOK FOR VALUE:
    - Is #{yes_team} being OVERVALUED because they're a big-market team?
    - Is #{no_team} being UNDERVALUED as a rested underdog?
    - Is one team on a B2B while the other is rested? HUGE edge.

    REST ADVANTAGE MATTERS:
    - Team on B2B vs rested opponent = 3-5 point swing
    - Stars sitting out changes everything
    - Late-season games: check if playoff position is locked

    RECOMMENDATION:
    - Recommend YES if #{yes_team}'s true win probability > #{yes_price}% + 5%
    - Recommend NO if #{no_team}'s true win probability > #{no_price}% + 5%
    - SKIP if uncertain or no clear edge

    Your reasoning MUST match your recommendation. Be SPECIFIC.
    """
  end

  # NHL-specific prompt
  defp build_nhl_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today) do
    """
    TODAY'S DATE: #{today}

    🏒 NHL HOCKEY GAME TO ANALYZE:
    #{title}
    #{subtitle_line}
    #{close_line}#{rules_section}

    CURRENT MARKET PRICES:
    - #{yes_team} to WIN: #{yes_price}¢ (implies #{yes_price}% probability)
    - #{no_team} to WIN: #{no_price}¢ (implies #{no_price}% probability)

    YOUR TASK - FIND THE EDGE:

    CRITICAL ANALYSIS POINTS:
    1. **GOALTENDING** (MOST IMPORTANT): Who's in net? Starter or backup? Hot or cold?
    2. **BACK-TO-BACK**: Is either team on a B2B? Backup goalie likely?
    3. **HOME ICE**: How strong is home ice advantage for these teams?
    4. **SCHEDULE/TRAVEL**: Long road trip? Time zone changes?
    5. **SPECIAL TEAMS**: Power play and penalty kill percentages matter.
    6. **DIVISIONAL**: Division rivals play tighter, more physical games.
    7. **INJURIES**: Top-line center out? Top-pair D-man injured?
    8. **PLAYOFF RACE**: Bubble team desperate? Team locked in coasting?

    GOALIE IS KEY:
    - An elite goalie can steal any game
    - Backup goalies = significant downgrade (often 10+ save % difference)
    - Check if starter played last night - unlikely to start again

    LOOK FOR VALUE:
    - Is #{yes_team} being OVERVALUED because of their star power?
    - Is #{no_team} being UNDERVALUED with a hot goalie?
    - Is one team on B2B with a backup goalie starting? FADE THEM.

    RECOMMENDATION:
    - Recommend YES if #{yes_team}'s true win probability > #{yes_price}% + 5%
    - Recommend NO if #{no_team}'s true win probability > #{no_price}% + 5%
    - SKIP if goalie situation unclear or no edge

    Your reasoning MUST match your recommendation. Be SPECIFIC.
    """
  end

  # MLB-specific prompt
  defp build_mlb_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today) do
    """
    TODAY'S DATE: #{today}

    ⚾ MLB BASEBALL GAME TO ANALYZE:
    #{title}
    #{subtitle_line}
    #{close_line}#{rules_section}

    CURRENT MARKET PRICES:
    - #{yes_team} to WIN: #{yes_price}¢ (implies #{yes_price}% probability)
    - #{no_team} to WIN: #{no_price}¢ (implies #{no_price}% probability)

    YOUR TASK - FIND THE EDGE:

    CRITICAL ANALYSIS POINTS:
    1. **STARTING PITCHER** (MOST IMPORTANT): Who's on the mound? Ace vs back-end?
    2. **PITCHER MATCHUP HISTORY**: How do these pitchers fare against this lineup?
    3. **BULLPEN STATE**: Any relievers overworked? Rested bullpen vs tired?
    4. **BALLPARK FACTORS**: Hitter-friendly or pitcher-friendly park?
    5. **WEATHER**: Wind direction? Temperature?
    6. **TRAVEL**: Cross-country flight? Day game after night game?
    7. **LINEUP**: Are stars in the lineup? Rest days common in MLB.
    8. **LEFTY/RIGHTY SPLITS**: Lineup construction vs pitcher handedness.
    9. **PLAYOFF RACE**: Teams fighting for position play harder.

    STARTING PITCHING IS KING:
    - An ace can neutralize any lineup
    - A struggling #5 starter against a good lineup = trouble
    - Recent performance matters more than season stats

    LOOK FOR VALUE:
    - Is #{yes_team}'s pitcher being OVERVALUED because of name recognition?
    - Is #{no_team} being UNDERVALUED with a solid starter?
    - Bullpen advantages late in games matter!

    RECOMMENDATION:
    - Recommend YES if #{yes_team}'s true win probability > #{yes_price}% + 5%
    - Recommend NO if #{no_team}'s true win probability > #{no_price}% + 5%
    - SKIP if pitching matchup is too close to call

    Your reasoning MUST match your recommendation. Be SPECIFIC.
    """
  end

  # Generic prompt for other sports
  defp build_generic_prompt(title, subtitle_line, yes_team, no_team, yes_price, no_price, close_line, rules_section, today, sport) do
    """
    TODAY'S DATE: #{today}

    GAME TO ANALYZE:
    #{title}
    #{subtitle_line}
    SPORT: #{sport |> to_string() |> String.upcase()}
    #{close_line}#{rules_section}

    CURRENT MARKET PRICES:
    - #{yes_team} to WIN: #{yes_price}¢ (implies #{yes_price}% probability)
    - #{no_team} to WIN: #{no_price}¢ (implies #{no_price}% probability)

    YOUR TASK - FIND THE EDGE:

    Consider all relevant factors:
    - Home/away advantage
    - Recent form and momentum
    - Key injuries or absences
    - Head-to-head history
    - Motivation and stakes
    - Public betting biases
    - Weather (if applicable)

    LOOK FOR VALUE:
    - Is #{yes_team} OVERVALUED or UNDERVALUED?
    - Is #{no_team} OVERVALUED or UNDERVALUED?
    - Is there a situational edge the market is missing?

    RECOMMENDATION:
    - Recommend YES if #{yes_team}'s true win probability > #{yes_price}% + 5%
    - Recommend NO if #{no_team}'s true win probability > #{no_price}% + 5%
    - SKIP if no clear edge

    Your reasoning MUST match your recommendation. Be SPECIFIC.
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

    # Get sport-specific system prompt for better analysis
    system_prompt = get_system_prompt(market.sport)

    Logger.info("[SportsAnalyzer] Analyzing: #{market.title} (#{market.sport}) with #{model}")

    # o-series models don't use temperature parameter
    case OpenAIClient.chat(prompt,
           system: system_prompt,
           model: model,
           max_tokens: 3000   # Allow detailed reasoning for comprehensive analysis
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

        # Build base analysis
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

        # Add draw probability for soccer matches
        analysis = if parsed["draw_probability"] do
          Map.put(analysis, :draw_probability, parsed["draw_probability"])
        else
          analysis
        end

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
