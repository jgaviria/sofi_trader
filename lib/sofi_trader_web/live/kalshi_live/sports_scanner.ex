defmodule SofiTraderWeb.KalshiLive.SportsScanner do
  @moduledoc """
  LiveView for the Sports AI Scanner.

  Shows sports markets, AI analysis results, and opportunities.
  """

  use SofiTraderWeb, :live_view

  alias SofiTrader.AI.{SportsScanner, SportsAnalyzer, SportsOpportunityScanner, OpenAIClient}
  alias SofiTrader.Kalshi.Portfolio

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to AI opportunities
      Phoenix.PubSub.subscribe(SofiTrader.PubSub, "ai:opportunities")
      Phoenix.PubSub.subscribe(SofiTrader.PubSub, "kalshi:alerts")
      # Refresh portfolio every 30 seconds
      :timer.send_interval(30_000, self(), :refresh_portfolio)
    end

    socket =
      socket
      |> assign(:page_title, "Sports AI Scanner")
      |> assign(:markets, [])
      |> assign(:opportunities, [])
      |> assign(:selected_market, nil)
      |> assign(:analysis_result, nil)
      |> assign(:loading_markets, false)
      |> assign(:loading_analysis, false)
      |> assign(:scanner_status, get_scanner_status())
      |> assign(:openai_configured, OpenAIClient.configured?())
      |> assign(:sport_filter, nil)
      |> assign(:error, nil)
      |> assign(:portfolio, nil)
      |> load_portfolio()

    {:ok, socket}
  end

  defp load_portfolio(socket) do
    case Portfolio.get_balance() do
      {:ok, balance} ->
        case Portfolio.list_positions(settlement_status: "unsettled", limit: 20) do
          {:ok, positions} ->
            assign(socket, :portfolio, %{
              balance: balance,
              positions: positions["market_positions"] || [],
              event_positions: positions["event_positions"] || []
            })
          _ ->
            assign(socket, :portfolio, %{balance: balance, positions: [], event_positions: []})
        end
      _ ->
        socket
    end
  end

  @impl true
  def handle_event("scan_markets", _, socket) do
    socket =
      socket
      |> assign(:loading_markets, true)
      |> assign(:error, nil)

    send(self(), :do_scan_markets)
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_sport", %{"sport" => sport}, socket) do
    sport_atom = string_to_sport(sport)

    socket =
      socket
      |> assign(:sport_filter, sport_atom)
      |> assign(:loading_markets, true)

    send(self(), :do_scan_markets)
    {:noreply, socket}
  end

  @impl true
  def handle_event("analyze_market", %{"ticker" => ticker}, socket) do
    market = Enum.find(socket.assigns.markets, &(&1.ticker == ticker))

    if market do
      socket =
        socket
        |> assign(:selected_market, market)
        |> assign(:loading_analysis, true)
        |> assign(:analysis_result, nil)

      send(self(), {:do_analyze, market})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("trigger_full_scan", _, socket) do
    SportsOpportunityScanner.scan_now()
    socket = assign(socket, :scanner_status, get_scanner_status())
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_scanner", _, socket) do
    status = socket.assigns.scanner_status
    SportsOpportunityScanner.set_enabled(!status.enabled)
    socket = assign(socket, :scanner_status, get_scanner_status())
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_selection", _, socket) do
    socket =
      socket
      |> assign(:selected_market, nil)
      |> assign(:analysis_result, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:do_scan_markets, socket) do
    opts = case socket.assigns.sport_filter do
      nil -> []
      sport -> [sport: sport]
    end

    case SportsScanner.scan(opts) do
      {:ok, markets} ->
        {:noreply, assign(socket, markets: markets, loading_markets: false)}

      {:error, reason} ->
        {:noreply, assign(socket, error: inspect(reason), loading_markets: false)}
    end
  end

  @impl true
  def handle_info({:do_analyze, market}, socket) do
    case SportsAnalyzer.analyze(market) do
      {:ok, analysis} ->
        {:noreply, assign(socket, analysis_result: analysis, loading_analysis: false)}

      {:error, reason} ->
        {:noreply, assign(socket, error: inspect(reason), loading_analysis: false)}
    end
  end

  @impl true
  def handle_info({:new_opportunity, market, analysis, alert}, socket) do
    opportunity = %{market: market, analysis: analysis, alert: alert, timestamp: DateTime.utc_now()}
    opportunities = [opportunity | socket.assigns.opportunities] |> Enum.take(20)
    {:noreply, assign(socket, opportunities: opportunities)}
  end

  @impl true
  def handle_info({:new_alert, alert}, socket) do
    if alert.alert_type == "ai_opportunity" do
      socket = assign(socket, :scanner_status, get_scanner_status())
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_portfolio, socket) do
    {:noreply, load_portfolio(socket)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp get_scanner_status do
    try do
      SportsOpportunityScanner.status()
    rescue
      _ -> %{enabled: false, scanning: false, api_configured: false}
    catch
      :exit, _ -> %{enabled: false, scanning: false, api_configured: false}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Header -->
        <div class="mb-6 flex justify-between items-center">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">Sports AI Scanner</h1>
            <p class="mt-2 text-sm text-gray-600">
              Scan sports markets and analyze with AI to find underpriced bets
            </p>
          </div>
          <.link
            navigate={~p"/kalshi"}
            class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50"
          >
            ← Back to Strategies
          </.link>
        </div>

        <!-- Portfolio Summary -->
        <%= if @portfolio do %>
          <div class="bg-gradient-to-r from-indigo-500 to-purple-600 rounded-lg shadow-lg p-4 mb-6 text-white">
            <div class="flex items-center justify-between">
              <!-- Balance Info -->
              <div class="flex items-center gap-8">
                <div>
                  <div class="text-xs text-indigo-200 uppercase tracking-wide">Cash Balance</div>
                  <div class="text-2xl font-bold"><%= format_dollars(@portfolio.balance["balance"]) %></div>
                </div>
                <div class="border-l border-indigo-400 pl-8">
                  <div class="text-xs text-indigo-200 uppercase tracking-wide">Current Trades</div>
                  <div class="text-2xl font-bold"><%= format_dollars(@portfolio.balance["portfolio_value"]) %></div>
                </div>
                <div class="border-l border-indigo-400 pl-8">
                  <div class="text-xs text-indigo-200 uppercase tracking-wide">Total Value</div>
                  <div class="text-2xl font-bold"><%= format_dollars((@portfolio.balance["balance"] || 0) + (@portfolio.balance["portfolio_value"] || 0)) %></div>
                </div>
              </div>

              <!-- Open Positions -->
              <div class="text-right">
                <div class="text-xs text-indigo-200 uppercase tracking-wide">Open Positions</div>
                <div class="text-2xl font-bold"><%= length(@portfolio.positions) %></div>
              </div>
            </div>

            <!-- Position Details (if any) -->
            <%= if length(@portfolio.positions) > 0 do %>
              <div class="mt-4 pt-4 border-t border-indigo-400">
                <div class="text-xs text-indigo-200 uppercase tracking-wide mb-2">Current Positions</div>
                <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-2">
                  <%= for pos <- Enum.take(@portfolio.positions, 6) do %>
                    <div class="bg-white/10 rounded-lg px-3 py-2">
                      <div class="text-sm font-medium truncate"><%= format_position_ticker(pos["ticker"]) %></div>
                      <div class="flex justify-between text-xs mt-1">
                        <span class={"#{if pos["position"] > 0, do: "text-green-300", else: "text-red-300"}"}>
                          <%= if pos["position"] > 0, do: "YES", else: "NO" %> <%= abs(pos["position"]) %> contracts
                        </span>
                        <span class="text-indigo-200"><%= format_dollars(pos["market_exposure"]) %></span>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <!-- API Status -->
        <%= unless @openai_configured do %>
          <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-6 mb-6">
            <div class="flex items-center gap-3">
              <svg class="h-8 w-8 text-yellow-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
              </svg>
              <div>
                <h3 class="text-lg font-semibold text-yellow-800">OpenAI API Not Configured</h3>
                <p class="text-yellow-700">
                  Set <code class="bg-yellow-100 px-1 rounded">OPENAI_API_KEY</code> environment variable to enable AI analysis.
                </p>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Instructions Panel -->
        <div class="bg-white rounded-lg shadow p-4 mb-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="p-2 bg-indigo-100 rounded-lg">
                <svg class="w-5 h-5 text-indigo-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
                </svg>
              </div>
              <div>
                <span class="font-medium text-gray-900">Manual Analysis Mode</span>
                <p class="text-sm text-gray-500">Click "Refresh" to load sports markets, then click any market to analyze with AI</p>
              </div>
            </div>

            <div class="text-sm text-gray-500">
              <%= length(@markets) %> markets loaded
            </div>
          </div>
        </div>

        <!-- Error Display -->
        <%= if @error do %>
          <div class="bg-red-50 border border-red-200 rounded-lg p-4 mb-6 text-red-800">
            <p class="font-semibold">Error</p>
            <p class="text-sm mt-1"><%= @error %></p>
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Markets Panel -->
          <div class="lg:col-span-2">
            <div class="bg-white rounded-lg shadow">
              <div class="p-4 border-b border-gray-100">
                <div class="flex items-center justify-between">
                  <h2 class="text-lg font-semibold text-gray-900">Sports Markets</h2>
                  <div class="flex items-center gap-2">
                    <!-- Sport Filter -->
                    <form phx-change="filter_sport" class="m-0">
                      <select
                        name="sport"
                        class="text-sm rounded-md border-gray-300"
                      >
                        <option value="all" selected={@sport_filter == nil}>All Sports</option>
                        <option value="soccer" selected={@sport_filter == :soccer}>Soccer</option>
                        <option value="nfl" selected={@sport_filter == :nfl}>NFL</option>
                        <option value="nba" selected={@sport_filter == :nba}>NBA</option>
                        <option value="nhl" selected={@sport_filter == :nhl}>NHL</option>
                        <option value="mlb" selected={@sport_filter == :mlb}>MLB</option>
                      </select>
                    </form>

                    <button
                      phx-click="scan_markets"
                      disabled={@loading_markets}
                      class="px-4 py-2 text-sm font-medium rounded-md bg-gray-100 text-gray-700 hover:bg-gray-200 disabled:opacity-50"
                    >
                      <%= if @loading_markets, do: "Scanning...", else: "Refresh" %>
                    </button>
                  </div>
                </div>
              </div>

              <div class="divide-y divide-gray-100 max-h-[600px] overflow-y-auto">
                <%= if Enum.empty?(@markets) do %>
                  <div class="p-8 text-center text-gray-500">
                    <%= if @loading_markets do %>
                      <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600 mx-auto mb-4"></div>
                      <p>Scanning for sports markets...</p>
                    <% else %>
                      <p>No sports markets found.</p>
                      <button
                        phx-click="scan_markets"
                        class="mt-4 text-indigo-600 hover:text-indigo-800"
                      >
                        Click to scan for markets
                      </button>
                    <% end %>
                  </div>
                <% else %>
                  <%= for market <- @markets do %>
                    <% {team_yes, team_no} = parse_teams_from_title(market.title) %>
                    <% game_status = get_game_status(market.game_date) %>
                    <% is_live = game_status.status == :live %>
                    <div class={"p-4 border-b border-gray-100 #{if @selected_market && @selected_market.ticker == market.ticker, do: "bg-indigo-50 ring-2 ring-indigo-500 ring-inset", else: "hover:bg-gray-50"}"}>
                      <!-- Header: Sport badge + Game time -->
                      <div class="flex items-center justify-between mb-3">
                        <div class="flex items-center gap-2">
                          <span class={"px-2 py-0.5 text-xs font-semibold rounded-full #{sport_badge_class(market.sport)}"}>
                            <%= market.sport |> to_string() |> String.upcase() %>
                          </span>
                          <%= unless is_live do %>
                            <span class={"text-xs font-medium px-2 py-0.5 rounded-full #{game_status_class(game_status)}"}>
                              <%= game_status.label %>
                            </span>
                          <% end %>
                          <%= if market.last_price do %>
                            <span class="text-xs text-gray-500">
                              Last: <%= market.last_price %>¢
                            </span>
                          <% end %>
                        </div>
                        <div class="text-xs">
                          <%= if is_live do %>
                            <span class="px-2 py-0.5 rounded-full bg-red-100 text-red-700 font-bold animate-pulse">🔴 LIVE</span>
                          <% else %>
                            <span class="text-gray-500"><%= format_game_date(market.game_date) %></span>
                          <% end %>
                        </div>
                      </div>

                      <!-- Teams matchup - Kalshi style -->
                      <div class="mb-4">
                        <!-- Column headers -->
                        <div class="flex items-center mb-2 pr-1">
                          <div class="flex-1 text-xs text-gray-400 pl-1">Market</div>
                          <div class="w-[72px] text-center text-xs text-gray-400">Yes</div>
                          <div class="w-[72px] text-center text-xs text-gray-400">No</div>
                        </div>

                        <!-- Team A row -->
                        <div class="flex items-center mb-2 pr-1">
                          <div class="flex-1 text-sm font-medium text-gray-800 truncate pl-1 pr-3"><%= team_yes %></div>
                          <div class={"w-[72px] h-10 flex items-center justify-center border border-gray-200 rounded-lg ml-1 #{if is_live, do: "animate-pulse", else: ""}"}>
                            <span class="text-sm font-medium text-green-600"><%= market.team_a_yes || "--" %>¢</span>
                          </div>
                          <div class="w-[72px] h-10 flex items-center justify-center border border-gray-200 rounded-lg ml-1">
                            <span class="text-sm font-medium text-red-500"><%= if market.team_a_yes, do: 100 - market.team_a_yes, else: "--" %>¢</span>
                          </div>
                        </div>

                        <!-- Team B row -->
                        <div class="flex items-center pr-1">
                          <div class="flex-1 text-sm font-medium text-gray-800 truncate pl-1 pr-3"><%= team_no %></div>
                          <div class={"w-[72px] h-10 flex items-center justify-center border border-gray-200 rounded-lg ml-1 #{if is_live, do: "animate-pulse", else: ""}"}>
                            <span class="text-sm font-medium text-green-600"><%= market.team_b_yes || "--" %>¢</span>
                          </div>
                          <div class="w-[72px] h-10 flex items-center justify-center border border-gray-200 rounded-lg ml-1">
                            <span class="text-sm font-medium text-red-500"><%= if market.team_b_yes, do: 100 - market.team_b_yes, else: "--" %>¢</span>
                          </div>
                        </div>
                      </div>

                      <!-- Footer: Volume + Analyze button -->
                      <div class="flex items-center justify-between pt-2 border-t border-gray-100">
                        <div class="text-xs text-gray-500">
                          Vol: <%= format_volume(market.volume) %> contracts
                        </div>
                        <button
                          phx-click="analyze_market"
                          phx-value-ticker={market.ticker}
                          disabled={@loading_analysis && @selected_market && @selected_market.ticker == market.ticker}
                          class="inline-flex items-center gap-1 px-3 py-1.5 text-xs font-medium rounded-lg bg-indigo-50 text-indigo-700 hover:bg-indigo-100 transition-colors disabled:opacity-50"
                        >
                          <%= if @loading_analysis && @selected_market && @selected_market.ticker == market.ticker do %>
                            <svg class="animate-spin w-3 h-3" fill="none" viewBox="0 0 24 24">
                              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                            </svg>
                            Analyzing...
                          <% else %>
                            <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
                            </svg>
                            AI Analysis
                          <% end %>
                        </button>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Analysis Panel -->
          <div class="lg:col-span-1">
            <div class="bg-white rounded-lg shadow sticky top-4">
              <div class="p-4 border-b border-gray-100">
                <div class="flex items-center justify-between">
                  <h2 class="text-lg font-semibold text-gray-900">AI Analysis</h2>
                  <%= if @selected_market do %>
                    <button phx-click="clear_selection" class="text-gray-400 hover:text-gray-600">
                      <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                      </svg>
                    </button>
                  <% end %>
                </div>
              </div>

              <div class="p-4">
                <%= if @loading_analysis do %>
                  <div class="text-center py-8">
                    <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600 mx-auto mb-4"></div>
                    <p class="text-gray-600">Analyzing with AI...</p>
                    <p class="text-xs text-gray-400 mt-1">This may take a few seconds</p>
                  </div>
                <% else %>
                  <%= if @selected_market do %>
                    <div class="mb-4">
                      <h3 class="font-medium text-gray-900 text-sm"><%= @selected_market.title %></h3>
                      <p class="text-xs text-gray-500 mt-1"><%= @selected_market.subtitle %></p>
                    </div>

                    <%= if @analysis_result do %>
                      <.analysis_result_card analysis={@analysis_result} market={@selected_market} />
                    <% else %>
                      <div class="text-center py-6 text-gray-500">
                        <p>Analysis pending...</p>
                      </div>
                    <% end %>
                  <% else %>
                    <div class="text-center py-8 text-gray-500">
                      <svg class="w-12 h-12 mx-auto mb-4 text-gray-300" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
                      </svg>
                      <p>Select a market to analyze</p>
                      <p class="text-xs mt-1">AI will evaluate if YES or NO is underpriced</p>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>

            <!-- Recent Opportunities -->
            <%= if length(@opportunities) > 0 do %>
              <div class="bg-white rounded-lg shadow mt-4">
                <div class="p-4 border-b border-gray-100">
                  <h2 class="text-lg font-semibold text-gray-900">Recent Opportunities</h2>
                </div>
                <div class="divide-y divide-gray-100 max-h-[300px] overflow-y-auto">
                  <%= for opp <- @opportunities do %>
                    <div class="p-3">
                      <div class="flex items-center gap-2 mb-1">
                        <span class={severity_badge_class(opp.alert.severity)}>
                          <%= opp.analysis.recommendation |> to_string() |> String.upcase() %>
                        </span>
                        <span class="text-xs text-gray-500">
                          <%= format_relative_time(opp.timestamp) %>
                        </span>
                      </div>
                      <p class="text-sm font-medium text-gray-900 line-clamp-1"><%= opp.market.title %></p>
                      <p class="text-xs text-gray-600 mt-1">
                        Edge: <%= opp.analysis.edge %>¢ | Confidence: <%= round(opp.analysis.confidence * 100) %>%
                      </p>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp analysis_result_card(assigns) do
    ~H"""
    <div class="space-y-4">
      <!-- Recommendation Badge -->
      <div class={"p-4 rounded-lg #{recommendation_bg_class(@analysis.recommendation)}"}>
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-2">
            <%= if @analysis.recommendation == :yes do %>
              <span class="text-2xl">🟢</span>
            <% else %>
              <%= if @analysis.recommendation == :no do %>
                <span class="text-2xl">🔴</span>
              <% else %>
                <span class="text-2xl">⚪</span>
              <% end %>
            <% end %>
            <span class="text-xl font-bold">
              BUY <%= @analysis.recommendation |> to_string() |> String.upcase() %>
            </span>
          </div>
          <span class={"px-3 py-1 text-sm font-medium rounded-full #{confidence_badge_class(@analysis.confidence)}"}>
            <%= round(@analysis.confidence * 100) %>% confident
          </span>
        </div>

        <!-- Price Comparison -->
        <div class="bg-white/50 rounded-lg p-3 mb-3">
          <div class="grid grid-cols-3 gap-2 text-center">
            <div>
              <div class="text-xs text-gray-500">Market Price</div>
              <div class="text-lg font-bold text-gray-900"><%= @market.best_yes_price || @analysis.current_yes_price %>¢</div>
            </div>
            <div>
              <div class="text-xs text-gray-500">AI Fair Value</div>
              <div class="text-lg font-bold text-indigo-600"><%= @analysis.fair_value_yes %>¢</div>
            </div>
            <div>
              <div class="text-xs text-gray-500">Edge</div>
              <div class={"text-lg font-bold #{if @analysis.edge >= 5, do: "text-green-600", else: "text-gray-600"}"}>
                <%= if @analysis.edge > 0, do: "+", else: "" %><%= @analysis.edge %>¢
              </div>
            </div>
          </div>
        </div>

        <!-- Draw Probability (Soccer only) -->
        <%= if Map.get(@analysis, :draw_probability) do %>
          <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-2 mb-3">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <span class="text-lg">⚽</span>
                <span class="text-sm font-medium text-yellow-800">Draw Probability</span>
              </div>
              <span class="text-lg font-bold text-yellow-700"><%= @analysis.draw_probability %>%</span>
            </div>
            <%= if @analysis.draw_probability > 30 do %>
              <p class="text-xs text-yellow-600 mt-1">High draw likelihood - consider this when betting!</p>
            <% end %>
          </div>
        <% end %>

        <!-- Edge Indicator -->
        <%= if @analysis.edge >= 5 do %>
          <div class="flex items-center gap-2 text-green-700 bg-green-100 rounded-lg p-2">
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
            </svg>
            <span class="text-sm font-medium">Value bet detected! <%= @analysis.edge %>¢ edge</span>
          </div>
        <% else %>
          <%= if @analysis.recommendation != :skip do %>
            <div class="flex items-center gap-2 text-orange-700 bg-orange-100 rounded-lg p-2">
              <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
                <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd" />
              </svg>
              <span class="text-sm font-medium">Marginal edge - proceed with caution</span>
            </div>
          <% end %>
        <% end %>
      </div>

      <!-- AI Reasoning -->
      <div class="bg-gray-50 rounded-lg p-4">
        <h4 class="text-sm font-semibold text-gray-900 mb-2 flex items-center gap-2">
          <svg class="w-4 h-4 text-indigo-500" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z" />
          </svg>
          AI Analysis
        </h4>
        <p class="text-sm text-gray-700 leading-relaxed"><%= @analysis.reasoning %></p>
      </div>

      <!-- Key Factors -->
      <%= if length(@analysis.key_factors) > 0 do %>
        <div>
          <h4 class="text-sm font-semibold text-gray-900 mb-2">Key Factors</h4>
          <div class="space-y-2">
            <%= for factor <- @analysis.key_factors do %>
              <div class="flex items-start gap-2 bg-indigo-50 rounded-lg p-2">
                <svg class="w-4 h-4 text-indigo-600 mt-0.5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
                  <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
                </svg>
                <span class="text-sm text-indigo-900"><%= factor %></span>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Market Info -->
      <div class="text-xs text-gray-500 border-t pt-3">
        <div class="flex justify-between">
          <span>Volume: <%= format_volume(@market.volume) %> contracts</span>
          <span>Spread: <%= @market.yes_spread %>¢</span>
        </div>
      </div>

      <!-- Action Button -->
      <%= if @analysis.edge >= 5 do %>
        <.link
          navigate={~p"/kalshi/new?market_ticker=#{@market.ticker}"}
          class="block w-full text-center px-4 py-3 text-sm font-medium rounded-lg text-white bg-green-600 hover:bg-green-700 transition-colors"
        >
          Place Bet on This Market →
        </.link>
      <% else %>
        <.link
          navigate={~p"/kalshi/new?market_ticker=#{@market.ticker}"}
          class="block w-full text-center px-4 py-2 text-sm font-medium rounded-lg text-gray-700 bg-gray-100 hover:bg-gray-200 transition-colors"
        >
          View Market Details
        </.link>
      <% end %>
    </div>
    """
  end

  # Helper functions

  # Safe string to sport atom conversion
  defp string_to_sport("all"), do: nil
  defp string_to_sport("soccer"), do: :soccer
  defp string_to_sport("nfl"), do: :nfl
  defp string_to_sport("nba"), do: :nba
  defp string_to_sport("nhl"), do: :nhl
  defp string_to_sport("mlb"), do: :mlb
  defp string_to_sport(_), do: nil

  defp sport_badge_class(:nfl), do: "bg-red-100 text-red-800"
  defp sport_badge_class(:nba), do: "bg-orange-100 text-orange-800"
  defp sport_badge_class(:mlb), do: "bg-blue-100 text-blue-800"
  defp sport_badge_class(:nhl), do: "bg-cyan-100 text-cyan-800"
  defp sport_badge_class(:soccer), do: "bg-green-100 text-green-800"
  defp sport_badge_class(:golf), do: "bg-emerald-100 text-emerald-800"
  defp sport_badge_class(:tennis), do: "bg-yellow-100 text-yellow-800"
  defp sport_badge_class(:mma), do: "bg-purple-100 text-purple-800"
  defp sport_badge_class(_), do: "bg-gray-100 text-gray-800"

  defp recommendation_bg_class(:yes), do: "bg-green-50 border border-green-200"
  defp recommendation_bg_class(:no), do: "bg-red-50 border border-red-200"
  defp recommendation_bg_class(_), do: "bg-gray-50 border border-gray-200"

  defp confidence_badge_class(confidence) when confidence >= 0.8, do: "bg-green-100 text-green-800"
  defp confidence_badge_class(confidence) when confidence >= 0.6, do: "bg-yellow-100 text-yellow-800"
  defp confidence_badge_class(_), do: "bg-gray-100 text-gray-800"

  defp severity_badge_class("critical"), do: "px-2 py-0.5 text-xs font-medium rounded-full bg-red-100 text-red-800"
  defp severity_badge_class("warning"), do: "px-2 py-0.5 text-xs font-medium rounded-full bg-yellow-100 text-yellow-800"
  defp severity_badge_class(_), do: "px-2 py-0.5 text-xs font-medium rounded-full bg-blue-100 text-blue-800"

  defp format_relative_time(nil), do: "Never"
  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp format_volume(nil), do: "0"
  defp format_volume(vol) when vol >= 1_000_000, do: "#{Float.round(vol / 1_000_000, 1)}M"
  defp format_volume(vol) when vol >= 1_000, do: "#{Float.round(vol / 1_000, 1)}K"
  defp format_volume(vol), do: "#{vol}"

  # Parse teams from title like "Houston at Los Angeles C Winner?" or "Utah vs San Antonio Winner?"
  defp parse_teams_from_title(title) do
    cond do
      # "Team A at Team B Winner?" - Team A is YES (away team asking if they win)
      String.contains?(title, " at ") ->
        case Regex.run(~r/(.+?) at (.+?) Winner\??/, title) do
          [_, team_a, team_b] -> {String.trim(team_a), String.trim(team_b)}
          _ -> parse_vs_title(title)
        end

      # "Team A vs Team B Winner?" - Team A is YES
      String.contains?(title, " vs ") ->
        parse_vs_title(title)

      true ->
        {title, "Other"}
    end
  end

  defp parse_vs_title(title) do
    case Regex.run(~r/(.+?) vs (.+?) Winner\??/, title) do
      [_, team_a, team_b] -> {String.trim(team_a), String.trim(team_b)}
      _ -> {title, "Other"}
    end
  end

  # Determine game status based on game date (Date type parsed from ticker)
  # For "today" games, check if it's likely live based on current time
  defp get_game_status(nil), do: %{status: :unknown, label: "Unknown"}
  defp get_game_status(%Date{} = game_date) do
    today = Date.utc_today()
    diff_days = Date.diff(game_date, today)
    current_hour = DateTime.utc_now().hour

    cond do
      diff_days < 0 -> %{status: :finished, label: "Finished"}
      # Today's games - check if likely in progress
      diff_days == 0 ->
        # Games typically run from ~6pm UTC (1pm ET) to ~4am UTC next day
        # If it's between 17:00 UTC and 04:00 UTC, games might be live
        if current_hour >= 17 or current_hour < 4 do
          %{status: :live, label: "🔴 LIVE"}
        else
          %{status: :today, label: "🏈 Today"}
        end
      diff_days == 1 -> %{status: :tomorrow, label: "Tomorrow"}
      diff_days <= 7 -> %{status: :this_week, label: "This Week"}
      true -> %{status: :upcoming, label: "Upcoming"}
    end
  end
  defp get_game_status(_), do: %{status: :unknown, label: "Unknown"}

  defp game_status_class(%{status: :live}), do: "bg-red-100 text-red-700 animate-pulse font-bold"
  defp game_status_class(%{status: :today}), do: "bg-green-100 text-green-700"
  defp game_status_class(%{status: :tomorrow}), do: "bg-blue-100 text-blue-700"
  defp game_status_class(%{status: :this_week}), do: "bg-indigo-100 text-indigo-700"
  defp game_status_class(%{status: :finished}), do: "bg-gray-200 text-gray-500"
  defp game_status_class(_), do: "bg-gray-100 text-gray-600"

  # Format game date for display
  defp format_game_date(nil), do: "TBD"
  defp format_game_date(%Date{} = game_date) do
    today = Date.utc_today()
    diff_days = Date.diff(game_date, today)

    cond do
      diff_days == 0 -> "Today"
      diff_days == 1 -> "Tomorrow"
      diff_days < 7 -> Calendar.strftime(game_date, "%A")  # Day name like "Sunday"
      true -> Calendar.strftime(game_date, "%b %d")  # "Dec 28"
    end
  end
  defp format_game_date(_), do: "TBD"

  # Format cents to dollars
  defp format_dollars(nil), do: "$0.00"
  defp format_dollars(cents) when is_integer(cents) do
    dollars = cents / 100
    "$#{:erlang.float_to_binary(dollars, decimals: 2)}"
  end
  defp format_dollars(_), do: "$0.00"

  # Format position ticker to readable name
  # e.g., "KXNFLGAME-25DEC28JACIND-JAC" -> "JAC @ IND (Dec 28)"
  defp format_position_ticker(ticker) when is_binary(ticker) do
    cond do
      # NFL/College Football game format
      String.contains?(ticker, "GAME-") ->
        parts = String.split(ticker, "-")
        case parts do
          [_, date_teams, team] ->
            # Extract date and make readable
            "#{team} (#{extract_date_from_ticker(date_teams)})"
          _ ->
            ticker
        end
      true ->
        ticker
    end
  end
  defp format_position_ticker(ticker), do: inspect(ticker)

  defp extract_date_from_ticker(date_teams) do
    case Regex.run(~r/(\d{2})([A-Z]{3})(\d{2})/, date_teams) do
      [_, _year, month, day] ->
        "#{month} #{day}"
      _ ->
        ""
    end
  end
end
