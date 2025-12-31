defmodule SofiTraderWeb.BettingLive.Statistics do
  @moduledoc """
  LiveView for betting statistics and performance tracking.
  """

  use SofiTraderWeb, :live_view

  alias SofiTrader.Betting
  alias SofiTrader.Betting.KalshiSync
  alias SofiTrader.Kalshi.Portfolio

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Auto-refresh every 60 seconds
      :timer.send_interval(60_000, self(), :refresh_stats)
    end

    # Load saved deposits/withdrawals from application env
    saved_deposits = Application.get_env(:sofi_trader, :kalshi_total_deposits)
    saved_withdrawals = Application.get_env(:sofi_trader, :kalshi_total_withdrawals)

    socket =
      socket
      |> assign(:page_title, "Betting Statistics")
      |> assign(:syncing, false)
      |> assign(:last_sync, nil)
      |> assign(:active_tab, :overview)
      |> assign(:time_range, :all)
      |> assign(:total_deposits_cents, saved_deposits)
      |> assign(:total_withdrawals_cents, saved_withdrawals || 0)
      |> assign(:editing_deposits, false)
      |> assign(:deposits_input, "")
      |> assign(:withdrawals_input, "")
      |> load_kalshi_stats()
      |> load_statistics()
      |> load_recent_bets()

    {:ok, socket}
  end

  defp load_kalshi_stats(socket) do
    # Load official Kalshi account stats
    kalshi_stats = case Portfolio.get_account_stats() do
      {:ok, stats} -> stats
      {:error, _} -> nil
    end

    assign(socket, :kalshi_stats, kalshi_stats)
  end

  @impl true
  def handle_event("sync_bets", _, socket) do
    socket = assign(socket, :syncing, true)
    send(self(), :do_sync)
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  @impl true
  def handle_event("change_time_range", %{"range" => range}, socket) do
    time_range = String.to_existing_atom(range)

    socket =
      socket
      |> assign(:time_range, time_range)
      |> load_statistics()
      |> load_recent_bets()

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    socket =
      socket
      |> load_kalshi_stats()
      |> load_statistics()
      |> load_recent_bets()

    {:noreply, socket}
  end

  @impl true
  def handle_event("edit_deposits", _, socket) do
    deposits = socket.assigns.total_deposits_cents
    withdrawals = socket.assigns.total_withdrawals_cents
    deposits_input = if deposits, do: Float.to_string(deposits / 100), else: ""
    withdrawals_input = if withdrawals && withdrawals > 0, do: Float.to_string(withdrawals / 100), else: ""

    {:noreply,
     socket
     |> assign(:editing_deposits, true)
     |> assign(:deposits_input, deposits_input)
     |> assign(:withdrawals_input, withdrawals_input)}
  end

  @impl true
  def handle_event("cancel_edit_deposits", _, socket) do
    {:noreply, assign(socket, editing_deposits: false, deposits_input: "", withdrawals_input: "")}
  end

  @impl true
  def handle_event("save_deposits", %{"deposits" => deposits_str, "withdrawals" => withdrawals_str}, socket) do
    with {:ok, deposits_cents} <- parse_dollars_to_cents(deposits_str),
         {:ok, withdrawals_cents} <- parse_dollars_to_cents(withdrawals_str, allow_empty: true) do
      # Save to application env (persists during runtime)
      Application.put_env(:sofi_trader, :kalshi_total_deposits, deposits_cents)
      Application.put_env(:sofi_trader, :kalshi_total_withdrawals, withdrawals_cents)

      {:noreply,
       socket
       |> assign(:total_deposits_cents, deposits_cents)
       |> assign(:total_withdrawals_cents, withdrawals_cents)
       |> assign(:editing_deposits, false)
       |> assign(:deposits_input, "")
       |> assign(:withdrawals_input, "")
       |> put_flash(:info, "Deposits & withdrawals saved")}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid amount. Enter numbers like 5000 or 5000.00")}
    end
  end

  defp parse_dollars_to_cents(str, opts \\ []) do
    str = String.trim(str) |> String.replace("$", "") |> String.replace(",", "")

    if str == "" and Keyword.get(opts, :allow_empty, false) do
      {:ok, 0}
    else
      case Float.parse(str) do
        {amount, _} when amount >= 0 -> {:ok, round(amount * 100)}
        _ -> {:error, :invalid}
      end
    end
  end

  @impl true
  def handle_info(:do_sync, socket) do
    case KalshiSync.full_sync() do
      {:ok, result} ->
        socket =
          socket
          |> assign(:syncing, false)
          |> assign(:last_sync, DateTime.utc_now())
          |> assign(:sync_result, result)
          |> load_statistics()
          |> load_recent_bets()

        {:noreply, put_flash(socket, :info, "Synced #{result.fills.new} new bets, settled #{result.settlements.settled}")}

      {:error, reason} ->
        socket =
          socket
          |> assign(:syncing, false)
          |> put_flash(:error, "Sync failed: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    {:noreply, load_statistics(socket)}
  end

  defp load_statistics(socket) do
    time_range = socket.assigns.time_range
    since = time_range_to_datetime(time_range)

    stats = Betting.get_statistics(since: since)
    ai_accuracy = Betting.analyze_ai_accuracy(since: since)
    edge_analysis = Betting.analyze_ai_edge_accuracy(since: since)

    socket
    |> assign(:stats, stats)
    |> assign(:ai_accuracy, ai_accuracy)
    |> assign(:edge_analysis, edge_analysis)
  end

  defp load_recent_bets(socket) do
    time_range = socket.assigns.time_range
    since = time_range_to_datetime(time_range)

    # Use aggregated positions instead of individual fills
    recent_bets = Betting.list_positions(limit: 50, since: since) |> Enum.take(20)

    assign(socket, :recent_bets, recent_bets)
  end

  defp time_range_to_datetime(:all), do: nil
  defp time_range_to_datetime(:today) do
    Date.utc_today()
    |> DateTime.new!(~T[00:00:00])
  end
  defp time_range_to_datetime(:week), do: DateTime.utc_now() |> DateTime.add(-7, :day)
  defp time_range_to_datetime(:month), do: DateTime.utc_now() |> DateTime.add(-30, :day)
  defp time_range_to_datetime(:quarter), do: DateTime.utc_now() |> DateTime.add(-90, :day)
  defp time_range_to_datetime(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Header -->
        <div class="mb-8 flex justify-between items-center">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">Betting Performance</h1>
            <p class="mt-2 text-sm text-gray-600">
              Track your sports betting results and AI prediction accuracy
            </p>
          </div>
          <div class="flex items-center gap-3">
            <.link
              navigate={~p"/kalshi/sports-scanner"}
              class="px-4 py-2 text-sm font-medium rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50"
            >
              ← Sports Scanner
            </.link>
            <button
              phx-click="refresh"
              class="px-4 py-2 text-sm font-medium rounded-lg border border-gray-300 text-gray-700 hover:bg-gray-50"
            >
              <svg class="w-4 h-4 inline mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
              </svg>
              Refresh
            </button>
            <button
              phx-click="sync_bets"
              disabled={@syncing}
              class="px-4 py-2 text-sm font-medium rounded-lg bg-indigo-600 text-white hover:bg-indigo-700 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <%= if @syncing do %>
                <svg class="animate-spin w-4 h-4 inline mr-1" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
                Syncing...
              <% else %>
                <svg class="w-4 h-4 inline mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M9 19l3 3m0 0l3-3m-3 3V10" />
                </svg>
                Sync from Kalshi
              <% end %>
            </button>
          </div>
        </div>

        <!-- Kalshi Official Stats Banner -->
        <%= if @kalshi_stats do %>
          <div class="bg-gradient-to-r from-indigo-600 to-purple-600 rounded-xl shadow-lg p-6 mb-8 text-white">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
                </svg>
                Kalshi Account (Official)
              </h2>
              <span class="text-xs text-indigo-200">Live from Kalshi API</span>
            </div>
            <div class="grid grid-cols-2 md:grid-cols-5 gap-6">
              <div>
                <div class="text-xs text-indigo-200 uppercase tracking-wide">Cash Balance</div>
                <div class="text-2xl font-bold"><%= format_money(@kalshi_stats.cash_balance_cents) %></div>
              </div>
              <div>
                <div class="text-xs text-indigo-200 uppercase tracking-wide">Open Positions</div>
                <div class="text-2xl font-bold"><%= format_money(@kalshi_stats.portfolio_value_cents) %></div>
              </div>
              <div>
                <div class="text-xs text-indigo-200 uppercase tracking-wide">Total Account Value</div>
                <div class="text-2xl font-bold"><%= format_money(@kalshi_stats.total_value_cents) %></div>
              </div>
              <!-- Profit Calculation -->
              <div>
                <div class="text-xs text-indigo-200 uppercase tracking-wide">Total Profit</div>
                <%= if @total_deposits_cents do %>
                  <% profit = @kalshi_stats.total_value_cents + @total_withdrawals_cents - @total_deposits_cents %>
                  <div class={"text-2xl font-bold #{if profit >= 0, do: "text-green-300", else: "text-red-300"}"}>
                    <%= format_money(profit) %>
                  </div>
                  <button phx-click="edit_deposits" class="text-xs text-indigo-200 hover:text-white underline">
                    <%= format_money(@total_deposits_cents) %> in, <%= format_money(@total_withdrawals_cents) %> out
                  </button>
                <% else %>
                  <button
                    phx-click="edit_deposits"
                    class="text-sm bg-white/20 hover:bg-white/30 px-3 py-1.5 rounded-lg transition"
                  >
                    Set deposits to calculate
                  </button>
                <% end %>
              </div>
              <%= if @kalshi_stats.pending_payout_cents > 0 do %>
                <div>
                  <div class="text-xs text-indigo-200 uppercase tracking-wide">Pending Payout</div>
                  <div class="text-2xl font-bold"><%= format_money(@kalshi_stats.pending_payout_cents) %></div>
                </div>
              <% end %>
            </div>

            <!-- Deposits/Withdrawals Edit Modal -->
            <%= if @editing_deposits do %>
              <div class="mt-4 p-4 bg-white/10 rounded-lg">
                <form phx-submit="save_deposits" class="flex flex-wrap items-end gap-4">
                  <div class="flex-1 min-w-[150px]">
                    <label class="text-xs text-indigo-200 block mb-1">Total Deposits</label>
                    <div class="flex items-center gap-2">
                      <span class="text-white">$</span>
                      <input
                        type="text"
                        name="deposits"
                        value={@deposits_input}
                        placeholder="e.g. 5000"
                        class="flex-1 px-3 py-2 rounded-lg bg-white/20 border border-white/30 text-white placeholder-indigo-200 focus:outline-none focus:ring-2 focus:ring-white/50"
                        autofocus
                      />
                    </div>
                  </div>
                  <div class="flex-1 min-w-[150px]">
                    <label class="text-xs text-indigo-200 block mb-1">Total Withdrawals</label>
                    <div class="flex items-center gap-2">
                      <span class="text-white">$</span>
                      <input
                        type="text"
                        name="withdrawals"
                        value={@withdrawals_input}
                        placeholder="0"
                        class="flex-1 px-3 py-2 rounded-lg bg-white/20 border border-white/30 text-white placeholder-indigo-200 focus:outline-none focus:ring-2 focus:ring-white/50"
                      />
                    </div>
                  </div>
                  <div class="flex gap-2">
                    <button type="submit" class="px-4 py-2 bg-green-500 hover:bg-green-600 rounded-lg font-medium">
                      Save
                    </button>
                    <button type="button" phx-click="cancel_edit_deposits" class="px-4 py-2 bg-white/20 hover:bg-white/30 rounded-lg">
                      Cancel
                    </button>
                  </div>
                </form>
                <p class="text-xs text-indigo-200 mt-2">
                  Profit = Current Value + Withdrawals - Deposits
                </p>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="bg-yellow-50 border border-yellow-200 rounded-xl p-4 mb-8">
            <div class="flex items-center gap-2 text-yellow-800">
              <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
              </svg>
              <span class="font-medium">Unable to load Kalshi account stats</span>
            </div>
            <p class="text-sm text-yellow-700 mt-1">Check that your Kalshi API key is configured correctly.</p>
          </div>
        <% end %>

        <!-- Tracked Stats Overview (from our database) -->
        <div class="mb-4 flex items-center justify-between">
          <h3 class="text-sm font-medium text-gray-500 uppercase tracking-wide">Tracked Performance (from synced bets)</h3>
          <!-- Time Range Toggle -->
          <div class="flex items-center gap-1 bg-gray-100 rounded-lg p-1">
            <.time_range_button range={:today} current={@time_range} label="Today" />
            <.time_range_button range={:week} current={@time_range} label="7D" />
            <.time_range_button range={:month} current={@time_range} label="30D" />
            <.time_range_button range={:quarter} current={@time_range} label="90D" />
            <.time_range_button range={:all} current={@time_range} label="All" />
          </div>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
          <.stat_card
            title="Total Bets"
            value={@stats.overall.total_bets}
            subtitle="settled positions"
            icon="ticket"
            color="blue"
          />
          <.stat_card
            title="Win Rate"
            value={"#{@stats.overall.win_rate}%"}
            subtitle={"#{@stats.overall.wins}W - #{@stats.overall.losses}L"}
            icon="trophy"
            color={if @stats.overall.win_rate >= 50, do: "green", else: "red"}
          />
          <.stat_card
            title="Total Profit"
            value={format_money(@stats.overall.total_profit_cents)}
            subtitle={"ROI: #{@stats.overall.roi_percent}%"}
            icon="currency"
            color={if @stats.overall.total_profit_cents >= 0, do: "green", else: "red"}
          />
          <.stat_card
            title="Total Wagered"
            value={format_money(@stats.overall.total_wagered_cents)}
            subtitle={"Avg bet: #{format_money(@stats.overall.avg_bet_size_cents)}"}
            icon="cash"
            color="purple"
          />
        </div>

        <!-- Tab Navigation -->
        <div class="border-b border-gray-200 mb-6">
          <nav class="-mb-px flex space-x-8">
            <button
              phx-click="change_tab"
              phx-value-tab="overview"
              class={"py-4 px-1 border-b-2 font-medium text-sm #{if @active_tab == :overview, do: "border-indigo-500 text-indigo-600", else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"}"}
            >
              Overview
            </button>
            <button
              phx-click="change_tab"
              phx-value-tab="by_sport"
              class={"py-4 px-1 border-b-2 font-medium text-sm #{if @active_tab == :by_sport, do: "border-indigo-500 text-indigo-600", else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"}"}
            >
              By Category
            </button>
            <button
              phx-click="change_tab"
              phx-value-tab="ai_analysis"
              class={"py-4 px-1 border-b-2 font-medium text-sm #{if @active_tab == :ai_analysis, do: "border-indigo-500 text-indigo-600", else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"}"}
            >
              AI Analysis
            </button>
            <button
              phx-click="change_tab"
              phx-value-tab="recent_bets"
              class={"py-4 px-1 border-b-2 font-medium text-sm #{if @active_tab == :recent_bets, do: "border-indigo-500 text-indigo-600", else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"}"}
            >
              Recent Bets
            </button>
          </nav>
        </div>

        <!-- Tab Content -->
        <%= case @active_tab do %>
          <% :overview -> %>
            <.overview_tab stats={@stats} />
          <% :by_sport -> %>
            <.by_sport_tab stats={@stats} />
          <% :ai_analysis -> %>
            <.ai_analysis_tab ai_accuracy={@ai_accuracy} edge_analysis={@edge_analysis} stats={@stats} />
          <% :recent_bets -> %>
            <.recent_bets_tab recent_bets={@recent_bets} />
        <% end %>
      </div>
    </div>
    """
  end

  # Time Range Button Component
  defp time_range_button(assigns) do
    ~H"""
    <button
      phx-click="change_time_range"
      phx-value-range={@range}
      class={"px-3 py-1.5 text-sm font-medium rounded-md transition-colors #{if @current == @range, do: "bg-white text-indigo-600 shadow-sm", else: "text-gray-600 hover:text-gray-900"}"}
    >
      <%= @label %>
    </button>
    """
  end

  # Stat Card Component
  defp stat_card(assigns) do
    ~H"""
    <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
      <div class="flex items-center justify-between mb-4">
        <div class={"p-3 rounded-lg #{color_bg(@color)}"}>
          <.stat_icon icon={@icon} color={@color} />
        </div>
      </div>
      <div class="text-2xl font-bold text-gray-900"><%= @value %></div>
      <div class="text-sm text-gray-500 mt-1"><%= @title %></div>
      <div class="text-xs text-gray-400 mt-1"><%= @subtitle %></div>
    </div>
    """
  end

  defp stat_icon(%{icon: "ticket"} = assigns) do
    ~H"""
    <svg class={"w-6 h-6 #{color_text(@color)}"} fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
    </svg>
    """
  end

  defp stat_icon(%{icon: "trophy"} = assigns) do
    ~H"""
    <svg class={"w-6 h-6 #{color_text(@color)}"} fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
    """
  end

  defp stat_icon(%{icon: "currency"} = assigns) do
    ~H"""
    <svg class={"w-6 h-6 #{color_text(@color)}"} fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
    """
  end

  defp stat_icon(%{icon: "cash"} = assigns) do
    ~H"""
    <svg class={"w-6 h-6 #{color_text(@color)}"} fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 9V7a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2m2 4h10a2 2 0 002-2v-6a2 2 0 00-2-2H9a2 2 0 00-2 2v6a2 2 0 002 2zm7-5a2 2 0 11-4 0 2 2 0 014 0z" />
    </svg>
    """
  end

  defp stat_icon(assigns) do
    ~H"""
    <svg class={"w-6 h-6 #{color_text(@color)}"} fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6" />
    </svg>
    """
  end

  # Overview Tab
  defp overview_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
      <!-- Recent Trend -->
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
        <h3 class="text-lg font-semibold text-gray-900 mb-4">Performance Trend</h3>
        <div class="space-y-4">
          <.trend_row label="Last 7 Days" stats={@stats.recent_trend.last_7_days} />
          <.trend_row label="Last 30 Days" stats={@stats.recent_trend.last_30_days} />
          <.trend_row label="Last 90 Days" stats={@stats.recent_trend.last_90_days} />
        </div>
      </div>

      <!-- Win/Loss Visual -->
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
        <h3 class="text-lg font-semibold text-gray-900 mb-4">Win/Loss Distribution</h3>
        <%= if @stats.overall.total_bets > 0 do %>
          <div class="mb-4">
            <div class="flex h-8 rounded-lg overflow-hidden">
              <div
                class="bg-green-500 flex items-center justify-center text-white text-sm font-medium"
                style={"width: #{@stats.overall.win_rate}%"}
              >
                <%= if @stats.overall.win_rate >= 15, do: "#{@stats.overall.wins}W" %>
              </div>
              <div
                class="bg-red-500 flex items-center justify-center text-white text-sm font-medium"
                style={"width: #{100 - @stats.overall.win_rate}%"}
              >
                <%= if (100 - @stats.overall.win_rate) >= 15, do: "#{@stats.overall.losses}L" %>
              </div>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-4 text-center">
            <div class="p-4 bg-green-50 rounded-lg">
              <div class="text-2xl font-bold text-green-700"><%= @stats.overall.wins %></div>
              <div class="text-sm text-green-600">Wins</div>
            </div>
            <div class="p-4 bg-red-50 rounded-lg">
              <div class="text-2xl font-bold text-red-700"><%= @stats.overall.losses %></div>
              <div class="text-sm text-red-600">Losses</div>
            </div>
          </div>
        <% else %>
          <div class="text-center text-gray-500 py-8">
            No settled bets yet. Sync from Kalshi to see your performance.
          </div>
        <% end %>
      </div>

      <!-- Profit Chart Placeholder -->
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6 lg:col-span-2">
        <h3 class="text-lg font-semibold text-gray-900 mb-4">Key Metrics</h3>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div class="text-center p-4 bg-gray-50 rounded-lg">
            <div class="text-xl font-bold text-gray-900"><%= format_money(@stats.overall.avg_profit_per_bet_cents) %></div>
            <div class="text-sm text-gray-500">Avg Profit/Bet</div>
          </div>
          <div class="text-center p-4 bg-gray-50 rounded-lg">
            <div class="text-xl font-bold text-gray-900"><%= format_money(@stats.overall.avg_bet_size_cents) %></div>
            <div class="text-sm text-gray-500">Avg Bet Size</div>
          </div>
          <div class="text-center p-4 bg-gray-50 rounded-lg">
            <div class="text-xl font-bold text-gray-900"><%= @stats.overall.roi_percent %>%</div>
            <div class="text-sm text-gray-500">ROI</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp trend_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between p-3 bg-gray-50 rounded-lg">
      <span class="font-medium text-gray-700"><%= @label %></span>
      <div class="flex items-center gap-4">
        <span class="text-sm text-gray-500"><%= @stats.total_bets %> bets</span>
        <span class={"text-sm font-medium #{if @stats.win_rate >= 50, do: "text-green-600", else: "text-red-600"}"}>
          <%= @stats.win_rate %>% WR
        </span>
        <span class={"text-sm font-bold #{if @stats.total_profit_cents >= 0, do: "text-green-600", else: "text-red-600"}"}>
          <%= format_money(@stats.total_profit_cents) %>
        </span>
      </div>
    </div>
    """
  end

  # By Sport Tab
  defp by_sport_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
      <%= for {sport, stats} <- @stats.by_sport do %>
        <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
          <div class="flex items-center gap-3 mb-4">
            <span class={"text-2xl"}><%= sport_emoji(sport) %></span>
            <h3 class="text-lg font-semibold text-gray-900 capitalize"><%= sport %></h3>
          </div>

          <div class="space-y-3">
            <div class="flex justify-between">
              <span class="text-gray-500">Bets</span>
              <span class="font-medium"><%= stats.total_bets %></span>
            </div>
            <div class="flex justify-between">
              <span class="text-gray-500">Record</span>
              <span class="font-medium"><%= stats.wins %>W - <%= stats.losses %>L</span>
            </div>
            <div class="flex justify-between">
              <span class="text-gray-500">Win Rate</span>
              <span class={"font-medium #{if stats.win_rate >= 50, do: "text-green-600", else: "text-red-600"}"}>
                <%= stats.win_rate %>%
              </span>
            </div>
            <div class="flex justify-between">
              <span class="text-gray-500">Profit</span>
              <span class={"font-bold #{if stats.total_profit_cents >= 0, do: "text-green-600", else: "text-red-600"}"}>
                <%= format_money(stats.total_profit_cents) %>
              </span>
            </div>
            <div class="flex justify-between">
              <span class="text-gray-500">ROI</span>
              <span class={"font-medium #{if stats.roi_percent >= 0, do: "text-green-600", else: "text-red-600"}"}>
                <%= stats.roi_percent %>%
              </span>
            </div>
          </div>

          <!-- Mini progress bar -->
          <div class="mt-4">
            <div class="h-2 bg-gray-200 rounded-full overflow-hidden">
              <div class="h-full bg-green-500" style={"width: #{stats.win_rate}%"}></div>
            </div>
          </div>
        </div>
      <% end %>

      <%= if map_size(@stats.by_sport) == 0 do %>
        <div class="col-span-full text-center text-gray-500 py-12">
          No bets by sport yet. Place some bets and sync to see breakdown.
        </div>
      <% end %>
    </div>
    """
  end

  # AI Analysis Tab
  defp ai_analysis_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- AI Accuracy Overview -->
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
        <h3 class="text-lg font-semibold text-gray-900 mb-4">AI Prediction Accuracy</h3>

        <%= if is_map(@ai_accuracy) && !Map.has_key?(@ai_accuracy, :message) do %>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
            <div class="text-center p-4 bg-indigo-50 rounded-lg">
              <div class="text-2xl font-bold text-indigo-700"><%= @ai_accuracy.total_ai_bets %></div>
              <div class="text-sm text-indigo-600">AI-Driven Bets</div>
            </div>
            <div class="text-center p-4 bg-green-50 rounded-lg">
              <div class="text-2xl font-bold text-green-700"><%= @ai_accuracy.ai_accuracy %>%</div>
              <div class="text-sm text-green-600">AI Accuracy</div>
            </div>
            <div class="text-center p-4 bg-blue-50 rounded-lg">
              <div class="text-2xl font-bold text-blue-700"><%= format_money(@ai_accuracy.ai_profit_cents) %></div>
              <div class="text-sm text-blue-600">AI Profit</div>
            </div>
            <div class="text-center p-4 bg-orange-50 rounded-lg">
              <div class="text-2xl font-bold text-orange-700"><%= @ai_accuracy.against_ai_bets %></div>
              <div class="text-sm text-orange-600">Against AI</div>
            </div>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div class="p-4 border border-green-200 rounded-lg bg-green-50">
              <div class="text-sm font-medium text-green-800 mb-2">Following AI Recommendations</div>
              <div class="text-xl font-bold text-green-700"><%= @ai_accuracy.ai_recommendations_followed %> bets</div>
              <div class="text-sm text-green-600"><%= @ai_accuracy.ai_correct_predictions %> correct predictions</div>
              <div class="text-lg font-semibold text-green-700 mt-2"><%= format_money(@ai_accuracy.ai_profit_cents) %> profit</div>
            </div>
            <div class="p-4 border border-orange-200 rounded-lg bg-orange-50">
              <div class="text-sm font-medium text-orange-800 mb-2">Going Against AI</div>
              <div class="text-xl font-bold text-orange-700"><%= @ai_accuracy.against_ai_bets %> bets</div>
              <div class="text-lg font-semibold text-orange-700 mt-2"><%= format_money(@ai_accuracy.against_ai_profit_cents) %> profit</div>
            </div>
          </div>
        <% else %>
          <div class="text-center text-gray-500 py-8">
            <%= @ai_accuracy[:message] || "No AI-driven bets found. Use AI Analysis on sports markets to track accuracy." %>
          </div>
        <% end %>
      </div>

      <!-- By Confidence Level -->
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
        <h3 class="text-lg font-semibold text-gray-900 mb-4">Performance by AI Confidence</h3>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <%= for {level, stats} <- @stats.by_ai_confidence do %>
            <div class={"p-4 rounded-lg border #{confidence_border_color(level)}"}>
              <div class="flex items-center gap-2 mb-3">
                <span class={"w-3 h-3 rounded-full #{confidence_dot_color(level)}"}></span>
                <span class="font-medium text-gray-900 capitalize"><%= level %> Confidence</span>
                <span class="text-xs text-gray-500">
                  <%= confidence_range(level) %>
                </span>
              </div>
              <div class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <span class="text-gray-500">Bets</span>
                  <span class="font-medium"><%= stats.total_bets %></span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500">Win Rate</span>
                  <span class={"font-medium #{if stats.win_rate >= 50, do: "text-green-600", else: "text-red-600"}"}>
                    <%= stats.win_rate %>%
                  </span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500">Profit</span>
                  <span class={"font-bold #{if stats.total_profit_cents >= 0, do: "text-green-600", else: "text-red-600"}"}>
                    <%= format_money(stats.total_profit_cents) %>
                  </span>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Edge Analysis -->
      <%= if is_map(@edge_analysis) && !Map.has_key?(@edge_analysis, :message) do %>
        <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
          <h3 class="text-lg font-semibold text-gray-900 mb-4">Performance by AI Edge</h3>
          <p class="text-sm text-gray-500 mb-4">How do bets perform based on the AI's estimated edge?</p>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <%= for {range, stats} <- @edge_analysis do %>
              <div class="p-4 bg-gray-50 rounded-lg">
                <div class="font-medium text-gray-900 mb-2"><%= range %> edge</div>
                <div class="space-y-1 text-sm">
                  <div class="flex justify-between">
                    <span class="text-gray-500">Bets</span>
                    <span><%= stats.total_bets %></span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-gray-500">Win Rate</span>
                    <span class={"font-medium #{if stats.win_rate >= 50, do: "text-green-600", else: "text-red-600"}"}>
                      <%= stats.win_rate %>%
                    </span>
                  </div>
                  <div class="flex justify-between">
                    <span class="text-gray-500">Profit</span>
                    <span class={"font-bold #{if stats.total_profit_cents >= 0, do: "text-green-600", else: "text-red-600"}"}>
                      <%= format_money(stats.total_profit_cents) %>
                    </span>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Recent Bets Tab
  defp recent_bets_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Recent Bets (includes pending) -->
      <div class="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
        <h3 class="text-lg font-semibold text-gray-900 mb-4">Recent Bets</h3>
        <%= if length(@recent_bets) > 0 do %>
          <div class="space-y-3">
            <%= for bet <- @recent_bets do %>
              <.bet_row bet={bet} />
            <% end %>
          </div>
        <% else %>
          <div class="text-center text-gray-500 py-8">
            No bets yet. Sync from Kalshi to import your trades.
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp bet_row(assigns) do
    ~H"""
    <div class={"flex items-center justify-between p-4 rounded-lg border #{bet_row_bg(@bet.status || @bet[:status])}"}>
      <div class="flex items-center gap-4">
        <!-- Status indicator -->
        <div class={"w-10 h-10 rounded-full flex items-center justify-center #{status_bg(@bet.status || @bet[:status])}"}>
          <.status_icon status={@bet.status || @bet[:status]} />
        </div>

        <!-- Bet info -->
        <div>
          <div class="font-medium text-gray-900">
            <%= @bet.market_title || @bet[:market_title] || @bet.market_ticker || @bet[:market_ticker] %>
          </div>
          <div class="text-sm text-gray-500 flex items-center gap-2">
            <span class={"px-2 py-0.5 rounded text-xs font-medium #{side_class(@bet.side || @bet[:side])}"}>
              <%= String.upcase(to_string(@bet.side || @bet[:side])) %>
            </span>
            <span><%= @bet.contracts || @bet[:contracts] %> contracts @ <%= @bet.price_cents || @bet[:price_cents] %>¢ avg</span>
            <%= if fill_count = (@bet[:fill_count] || 1) > 1 do %>
              <span class="text-xs text-indigo-500">(<%= fill_count %> fills)</span>
            <% end %>
            <%= if sport = (@bet.sport || @bet[:sport]) do %>
              <span class="text-gray-400">•</span>
              <span><%= sport_emoji(sport) %> <%= sport %></span>
            <% end %>
          </div>
          <%= if ai_rec = (@bet.ai_recommendation || @bet[:ai_recommendation]) do %>
            <div class="text-xs text-indigo-600 mt-1">
              AI: <%= String.upcase(ai_rec) %> @ <%= format_confidence(@bet.ai_confidence || @bet[:ai_confidence]) %>% confidence
            </div>
          <% end %>
        </div>
      </div>

      <!-- Result -->
      <div class="text-right">
        <%= if (@bet.status || @bet[:status]) == "pending" do %>
          <div class="text-yellow-600 font-medium">Pending</div>
          <div class="text-sm text-gray-500">Cost: <%= format_money(@bet.cost_cents || @bet[:cost_cents]) %></div>
        <% else %>
          <div class={"font-bold #{profit_color(@bet.profit_cents || @bet[:profit_cents])}"}>
            <%= format_money(@bet.profit_cents || @bet[:profit_cents] || 0) %>
          </div>
          <div class="text-sm text-gray-500">
            ROI: <%= format_roi(@bet.roi_percent || @bet[:roi_percent]) %>%
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_confidence(nil), do: "0"
  defp format_confidence(%Decimal{} = d), do: Float.round(Decimal.to_float(d) * 100, 0)
  defp format_confidence(f) when is_float(f), do: Float.round(f * 100, 0)
  defp format_confidence(_), do: "0"

  defp format_roi(nil), do: "0.0"
  defp format_roi(%Decimal{} = d), do: Decimal.to_float(d) |> Float.round(1)
  defp format_roi(f) when is_float(f), do: Float.round(f, 1)
  defp format_roi(_), do: "0.0"

  defp status_icon(%{status: "won"} = assigns) do
    ~H"""
    <svg class="w-5 h-5 text-green-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
    </svg>
    """
  end

  defp status_icon(%{status: "lost"} = assigns) do
    ~H"""
    <svg class="w-5 h-5 text-red-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
    </svg>
    """
  end

  defp status_icon(%{status: "pending"} = assigns) do
    ~H"""
    <svg class="w-5 h-5 text-yellow-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
    """
  end

  defp status_icon(assigns) do
    ~H"""
    <svg class="w-5 h-5 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8.228 9c.549-1.165 2.03-2 3.772-2 2.21 0 4 1.343 4 3 0 1.4-1.278 2.575-3.006 2.907-.542.104-.994.54-.994 1.093m0 3h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
    </svg>
    """
  end

  # Helper functions
  defp format_money(nil), do: "$0.00"
  defp format_money(cents) when is_integer(cents) do
    dollars = cents / 100
    sign = if dollars < 0, do: "-", else: ""
    "#{sign}$#{:erlang.float_to_binary(abs(dollars), decimals: 2)}"
  end
  defp format_money(_), do: "$0.00"

  defp color_bg("green"), do: "bg-green-100"
  defp color_bg("red"), do: "bg-red-100"
  defp color_bg("blue"), do: "bg-blue-100"
  defp color_bg("purple"), do: "bg-purple-100"
  defp color_bg(_), do: "bg-gray-100"

  defp color_text("green"), do: "text-green-600"
  defp color_text("red"), do: "text-red-600"
  defp color_text("blue"), do: "text-blue-600"
  defp color_text("purple"), do: "text-purple-600"
  defp color_text(_), do: "text-gray-600"

  defp sport_emoji("soccer"), do: "⚽"
  defp sport_emoji("nfl"), do: "🏈"
  defp sport_emoji("nba"), do: "🏀"
  defp sport_emoji("nhl"), do: "🏒"
  defp sport_emoji("mlb"), do: "⚾"
  defp sport_emoji("crypto"), do: "₿"
  defp sport_emoji("politics"), do: "🗳️"
  defp sport_emoji("economics"), do: "📊"
  defp sport_emoji("weather"), do: "🌤️"
  defp sport_emoji("stocks"), do: "📈"
  defp sport_emoji("entertainment"), do: "🎬"
  defp sport_emoji("science"), do: "🚀"
  defp sport_emoji("other"), do: "🎯"
  defp sport_emoji(_), do: "🎯"

  defp status_bg("won"), do: "bg-green-100"
  defp status_bg("lost"), do: "bg-red-100"
  defp status_bg("pending"), do: "bg-yellow-100"
  defp status_bg(_), do: "bg-gray-100"

  defp bet_row_bg("won"), do: "bg-green-50 border-green-200"
  defp bet_row_bg("lost"), do: "bg-red-50 border-red-200"
  defp bet_row_bg("pending"), do: "bg-yellow-50 border-yellow-200"
  defp bet_row_bg(_), do: "bg-gray-50 border-gray-200"

  defp side_class("yes"), do: "bg-green-100 text-green-800"
  defp side_class("no"), do: "bg-red-100 text-red-800"
  defp side_class(_), do: "bg-gray-100 text-gray-800"

  defp profit_color(nil), do: "text-gray-600"
  defp profit_color(cents) when cents >= 0, do: "text-green-600"
  defp profit_color(_), do: "text-red-600"

  defp confidence_border_color(:high), do: "border-green-200 bg-green-50"
  defp confidence_border_color(:medium), do: "border-yellow-200 bg-yellow-50"
  defp confidence_border_color(:low), do: "border-red-200 bg-red-50"
  defp confidence_border_color(_), do: "border-gray-200 bg-gray-50"

  defp confidence_dot_color(:high), do: "bg-green-500"
  defp confidence_dot_color(:medium), do: "bg-yellow-500"
  defp confidence_dot_color(:low), do: "bg-red-500"
  defp confidence_dot_color(_), do: "bg-gray-500"

  defp confidence_range(:high), do: "(80%+)"
  defp confidence_range(:medium), do: "(60-80%)"
  defp confidence_range(:low), do: "(<60%)"
  defp confidence_range(_), do: ""
end
