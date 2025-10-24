defmodule SofiTraderWeb.StrategyLive.Show do
  use SofiTraderWeb, :live_view

  alias SofiTrader.Strategies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    strategy = Strategies.get_strategy_with_positions!(id)

    if connected?(socket) do
      # Subscribe to strategy updates
      Phoenix.PubSub.subscribe(SofiTrader.PubSub, "strategy:#{id}")
      # Subscribe to market data for real-time updates
      Phoenix.PubSub.subscribe(SofiTrader.PubSub, "market_data:#{strategy.symbol}")
      # Refresh data every 2 seconds
      :timer.send_interval(2000, self(), :refresh_data)
    end

    socket =
      socket
      |> assign(:strategy, strategy)
      |> assign(:positions, Strategies.list_positions(strategy.id))
      |> assign(:open_positions, Strategies.list_open_positions(strategy.id))
      |> assign(:trades, Strategies.list_trades(strategy.id, 50))
      |> assign(:runtime_status, get_runtime_status(strategy.id, strategy.symbol))
      |> assign(:last_candle, nil)
      |> assign(:dashboard_data, get_dashboard_data(strategy.id, strategy))

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    strategy = Strategies.get_strategy_with_positions!(socket.assigns.strategy.id)

    socket =
      socket
      |> assign(:strategy, strategy)
      |> assign(:positions, Strategies.list_positions(strategy.id))
      |> assign(:open_positions, Strategies.list_open_positions(strategy.id))
      |> assign(:trades, Strategies.list_trades(strategy.id, 50))
      |> assign(:runtime_status, get_runtime_status(strategy.id, strategy.symbol))
      |> assign(:dashboard_data, get_dashboard_data(strategy.id, strategy))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:candle_closed, candle, _price_history}, socket) do
    socket = assign(socket, :last_candle, candle)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Header -->
        <div class="mb-8">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <.link navigate={~p"/strategies"} class="text-gray-400 hover:text-gray-600">
                <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
                </svg>
              </.link>
              <div>
                <h1 class="text-3xl font-bold text-gray-900"><%= @strategy.name %></h1>
                <p class="mt-1 text-sm text-gray-600">
                  <%= @strategy.symbol %> · <%= format_strategy_type(@strategy.type) %>
                </p>
              </div>
            </div>
            <span class={status_badge_class(@strategy.status)}>
              <%= String.capitalize(@strategy.status) %>
            </span>
          </div>
        </div>

        <!-- Runtime Status -->
        <div class="bg-white rounded-lg shadow mb-6">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-lg font-semibold text-gray-900 flex items-center gap-2">
              Runtime Status
              <%= if @runtime_status.running do %>
                <span class="relative flex h-3 w-3">
                  <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-green-400 opacity-75"></span>
                  <span class="relative inline-flex rounded-full h-3 w-3 bg-green-500"></span>
                </span>
              <% else %>
                <span class="relative inline-flex rounded-full h-3 w-3 bg-gray-400"></span>
              <% end %>
            </h2>
          </div>
          <div class="px-6 py-4">
            <div class="grid grid-cols-1 md:grid-cols-4 gap-6">
              <div>
                <div class="text-sm text-gray-500 mb-1">Process Status</div>
                <div class="text-lg font-semibold">
                  <%= if @runtime_status.running do %>
                    <span class="text-green-600">✓ Running</span>
                  <% else %>
                    <span class="text-gray-400">● Stopped</span>
                  <% end %>
                </div>
                <div class="text-xs text-gray-500 mt-1">
                  Timeframe: <%= @runtime_status.timeframe %>
                </div>
              </div>

              <div>
                <div class="text-sm text-gray-500 mb-1">Data Source</div>
                <div class="text-lg font-semibold text-gray-900">
                  <%= String.capitalize(@runtime_status.data_source || "polling") %>
                </div>
                <div class="text-xs text-gray-500 mt-1">
                  <%= if @runtime_status.data_source == "websocket" do %>
                    Real-time streaming
                  <% else %>
                    10s REST polling
                  <% end %>
                </div>
              </div>

              <div>
                <div class="text-sm text-gray-500 mb-1">Price History</div>
                <div class="text-lg font-semibold text-gray-900">
                  <%= @runtime_status.price_history_count %> candles
                </div>
                <%= if @runtime_status.current_price do %>
                  <div class="text-xs text-gray-500 mt-1">
                    Current: $<%= format_price(@runtime_status.current_price) %>
                  </div>
                <% end %>
              </div>

              <div>
                <div class="text-sm text-gray-500 mb-1">Last Activity</div>
                <div class="text-lg font-semibold text-gray-900">
                  <%= if @last_candle do %>
                    <%= format_relative_time(@last_candle.end_time) %>
                  <% else %>
                    <span class="text-gray-400">Waiting...</span>
                  <% end %>
                </div>
                <%= if @last_candle do %>
                  <div class="text-xs text-gray-500 mt-1">
                    O: $<%= format_price(@last_candle.open) %>
                    H: $<%= format_price(@last_candle.high) %>
                    L: $<%= format_price(@last_candle.low) %>
                    C: $<%= format_price(@last_candle.close) %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <!-- Live Strategy Dashboard -->
        <div class="bg-white rounded-lg shadow mb-6">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-lg font-semibold text-gray-900">Live Strategy Dashboard</h2>
            <p class="text-sm text-gray-500 mt-1">Real-time signal analysis and entry conditions</p>
          </div>

          <%= if @dashboard_data.has_data do %>
            <div class="px-6 py-6">
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
                <!-- Left Column: RSI Gauge and Signal Strength -->
                <div class="space-y-6">
                  <!-- RSI Gauge -->
                  <div>
                    <div class="flex items-center justify-between mb-3">
                      <div>
                        <h3 class="text-sm font-semibold text-gray-700">RSI Indicator</h3>
                        <p class="text-xs text-gray-500">Period: <%= @dashboard_data.rsi_period %></p>
                      </div>
                      <%= if @dashboard_data.rsi do %>
                        <div class="text-right">
                          <div class="text-3xl font-bold" style={"color: #{rsi_color(@dashboard_data.rsi, @dashboard_data.oversold_threshold, @dashboard_data.overbought_threshold)}"}>
                            <%= Float.round(@dashboard_data.rsi, 2) %>
                          </div>
                          <div class="text-xs text-gray-500">
                            <%= signal_type_label(@dashboard_data.signal_type) %>
                          </div>
                        </div>
                      <% else %>
                        <div class="text-2xl font-bold text-gray-400">--</div>
                      <% end %>
                    </div>

                    <!-- RSI Visual Bar -->
                    <div class="relative w-full h-12 bg-gradient-to-r from-red-500 via-yellow-400 via-green-500 via-yellow-400 to-red-500 rounded-lg overflow-hidden">
                      <!-- Zone markers -->
                      <div class="absolute inset-0 flex items-center">
                        <div class="absolute left-0 w-[30%] flex items-center justify-center">
                          <span class="text-xs font-semibold text-white drop-shadow">OVERSOLD</span>
                        </div>
                        <div class="absolute left-[30%] w-[40%] flex items-center justify-center">
                          <span class="text-xs font-semibold text-gray-700">NEUTRAL</span>
                        </div>
                        <div class="absolute right-0 w-[30%] flex items-center justify-center">
                          <span class="text-xs font-semibold text-white drop-shadow">OVERBOUGHT</span>
                        </div>
                      </div>

                      <!-- RSI Position Indicator -->
                      <%= if @dashboard_data.rsi do %>
                        <div
                          class="absolute top-0 bottom-0 w-1 bg-gray-900 shadow-lg transition-all duration-500"
                          style={"left: #{@dashboard_data.rsi}%"}
                        >
                          <div class="absolute -top-1 left-1/2 transform -translate-x-1/2 w-3 h-3 bg-gray-900 rounded-full"></div>
                          <div class="absolute -bottom-1 left-1/2 transform -translate-x-1/2 w-3 h-3 bg-gray-900 rounded-full"></div>
                        </div>
                      <% end %>
                    </div>

                    <!-- Threshold markers -->
                    <div class="relative w-full h-6 flex items-center justify-between text-xs text-gray-500 px-1">
                      <span>0</span>
                      <span class="absolute" style="left: 30%">30</span>
                      <span class="absolute" style="left: 70%">70</span>
                      <span>100</span>
                    </div>
                  </div>

                  <!-- Signal Strength -->
                  <div>
                    <div class="flex items-center justify-between mb-2">
                      <h3 class="text-sm font-semibold text-gray-700">Signal Strength</h3>
                      <span class="text-lg font-bold" style={"color: #{signal_strength_color(@dashboard_data.signal_strength)}"}>
                        <%= Float.round(@dashboard_data.signal_strength, 1) %>%
                      </span>
                    </div>
                    <div class="w-full bg-gray-200 rounded-full h-4 overflow-hidden">
                      <div
                        class="h-full transition-all duration-500 rounded-full"
                        style={"width: #{@dashboard_data.signal_strength}%; background-color: #{signal_strength_color(@dashboard_data.signal_strength)}"}
                      ></div>
                    </div>
                    <p class="text-xs text-gray-500 mt-2">
                      <%= if @dashboard_data.signal_strength > 50 do %>
                        <strong>Strong signal</strong> - The strategy is detecting favorable conditions
                      <% else %>
                        Waiting for stronger signal
                      <% end %>
                    </p>
                  </div>

                  <!-- Current Market Info -->
                  <div class="bg-gray-50 rounded-lg p-4">
                    <div class="grid grid-cols-2 gap-4">
                      <div>
                        <div class="text-xs text-gray-500">Current Price</div>
                        <div class="text-xl font-bold text-gray-900">
                          <%= if @dashboard_data.current_price do %>
                            $<%= format_price(@dashboard_data.current_price) %>
                          <% else %>
                            <span class="text-gray-400">--</span>
                          <% end %>
                        </div>
                      </div>
                      <div>
                        <div class="text-xs text-gray-500">Trade Signal</div>
                        <div class="text-xl font-bold">
                          <%= case @dashboard_data.signal_type do %>
                            <% :buy -> %><span class="text-green-600">BUY</span>
                            <% :sell -> %><span class="text-red-600">SELL</span>
                            <% :neutral -> %><span class="text-gray-400">HOLD</span>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>

                <!-- Right Column: Entry Conditions Checklist -->
                <div>
                  <h3 class="text-sm font-semibold text-gray-700 mb-4">Entry Conditions Checklist</h3>
                  <div class="space-y-3">
                    <!-- RSI Signal -->
                    <div class="flex items-start gap-3 p-3 rounded-lg" style={"background-color: #{if @dashboard_data.conditions.rsi_signal, do: "#dcfce7", else: "#f9fafb"}"}>
                      <div class="flex-shrink-0 mt-0.5">
                        <%= if @dashboard_data.conditions.rsi_signal do %>
                          <svg class="w-5 h-5 text-green-600" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
                          </svg>
                        <% else %>
                          <svg class="w-5 h-5 text-gray-400" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/>
                          </svg>
                        <% end %>
                      </div>
                      <div class="flex-1">
                        <div class="text-sm font-medium text-gray-900">
                          RSI Signal (<%= @dashboard_data.oversold_threshold %>)
                        </div>
                        <div class="text-xs text-gray-600 mt-0.5">
                          <%= if @dashboard_data.conditions.rsi_value do %>
                            Current RSI: <%= Float.round(@dashboard_data.conditions.rsi_value, 2) %>
                            <%= if @dashboard_data.conditions.rsi_signal do %>
                              (Below threshold ✓)
                            <% else %>
                              (Above threshold)
                            <% end %>
                          <% else %>
                            Waiting for data...
                          <% end %>
                        </div>
                      </div>
                    </div>

                    <!-- No Open Positions -->
                    <div class="flex items-start gap-3 p-3 rounded-lg" style={"background-color: #{if @dashboard_data.conditions.no_open_positions, do: "#dcfce7", else: "#fef3c7"}"}>
                      <div class="flex-shrink-0 mt-0.5">
                        <%= if @dashboard_data.conditions.no_open_positions do %>
                          <svg class="w-5 h-5 text-green-600" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
                          </svg>
                        <% else %>
                          <svg class="w-5 h-5 text-yellow-600" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/>
                          </svg>
                        <% end %>
                      </div>
                      <div class="flex-1">
                        <div class="text-sm font-medium text-gray-900">No Open Positions</div>
                        <div class="text-xs text-gray-600 mt-0.5">
                          <%= if @dashboard_data.conditions.no_open_positions do %>
                            Ready to open new position
                          <% else %>
                            Position already open
                          <% end %>
                        </div>
                      </div>
                    </div>

                    <!-- Capital Available -->
                    <div class="flex items-start gap-3 p-3 rounded-lg" style={"background-color: #{if @dashboard_data.conditions.capital_available, do: "#dcfce7", else: "#fee2e2"}"}>
                      <div class="flex-shrink-0 mt-0.5">
                        <%= if @dashboard_data.conditions.capital_available do %>
                          <svg class="w-5 h-5 text-green-600" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
                          </svg>
                        <% else %>
                          <svg class="w-5 h-5 text-red-600" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/>
                          </svg>
                        <% end %>
                      </div>
                      <div class="flex-1">
                        <div class="text-sm font-medium text-gray-900">Capital Available</div>
                        <div class="text-xs text-gray-600 mt-0.5">
                          Position Size: <%= @strategy.risk_params["position_size_pct"] || "10.0" %>%
                        </div>
                      </div>
                    </div>

                    <!-- Risk Management Checks -->
                    <div class="flex items-start gap-3 p-3 rounded-lg" style={"background-color: #{if @dashboard_data.conditions.risk_checks, do: "#dcfce7", else: "#f9fafb"}"}>
                      <div class="flex-shrink-0 mt-0.5">
                        <%= if @dashboard_data.conditions.risk_checks do %>
                          <svg class="w-5 h-5 text-green-600" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
                          </svg>
                        <% else %>
                          <svg class="w-5 h-5 text-gray-400" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/>
                          </svg>
                        <% end %>
                      </div>
                      <div class="flex-1">
                        <div class="text-sm font-medium text-gray-900">Risk Management</div>
                        <div class="text-xs text-gray-600 mt-0.5">
                          <%= @dashboard_data.risk_message %>
                        </div>
                      </div>
                    </div>
                  </div>

                  <!-- Ready to Trade Banner -->
                  <%= if @dashboard_data.can_trade do %>
                    <div class="mt-6 bg-green-50 border-2 border-green-500 rounded-lg p-4">
                      <div class="flex items-center gap-3">
                        <svg class="w-8 h-8 text-green-600 animate-pulse" fill="currentColor" viewBox="0 0 20 20">
                          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
                        </svg>
                        <div class="flex-1">
                          <div class="font-bold text-green-900 text-lg">Ready to Trade!</div>
                          <div class="text-sm text-green-700">All conditions met. Strategy will execute on next candle close.</div>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% else %>
            <div class="px-6 py-6">
              <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
                <div class="flex items-center gap-3">
                  <svg class="w-6 h-6 text-yellow-600" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/>
                  </svg>
                  <div class="flex-1">
                    <div class="font-semibold text-yellow-900">Dashboard Not Available</div>
                    <div class="text-sm text-yellow-700 mt-1">
                      <%= @dashboard_data.risk_message %>
                    </div>
                    <div class="text-xs text-yellow-600 mt-2">
                      Debug: has_data=<%= @dashboard_data.has_data %>,
                      signal_type=<%= @dashboard_data.signal_type %>,
                      rsi=<%= inspect(@dashboard_data.rsi) %>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <!-- Performance Stats -->
        <div class="grid grid-cols-1 md:grid-cols-4 gap-6 mb-8">
          <div class="bg-white rounded-lg shadow p-6">
            <div class="text-sm text-gray-500 mb-1">Total P&L</div>
            <div class={["text-2xl font-bold", pnl_class(get_in(@strategy.stats, ["total_pnl"]) || 0)]}>
              $<%= format_number(get_in(@strategy.stats, ["total_pnl"]) || 0) %>
            </div>
          </div>

          <div class="bg-white rounded-lg shadow p-6">
            <div class="text-sm text-gray-500 mb-1">Win Rate</div>
            <div class="text-2xl font-bold text-gray-900">
              <%= format_percent(get_in(@strategy.stats, ["win_rate"]) || 0) %>
            </div>
            <div class="text-xs text-gray-500 mt-1">
              <%= get_in(@strategy.stats, ["winning_trades"]) || 0 %>W /
              <%= get_in(@strategy.stats, ["losing_trades"]) || 0 %>L
            </div>
          </div>

          <div class="bg-white rounded-lg shadow p-6">
            <div class="text-sm text-gray-500 mb-1">Total Trades</div>
            <div class="text-2xl font-bold text-gray-900">
              <%= get_in(@strategy.stats, ["total_trades"]) || 0 %>
            </div>
          </div>

          <div class="bg-white rounded-lg shadow p-6">
            <div class="text-sm text-gray-500 mb-1">Open Positions</div>
            <div class="text-2xl font-bold text-gray-900">
              <%= length(@open_positions) %>
            </div>
          </div>
        </div>

        <!-- Open Positions -->
        <%= if !Enum.empty?(@open_positions) do %>
          <div class="bg-white shadow rounded-lg mb-8">
            <div class="px-6 py-4 border-b border-gray-200">
              <h2 class="text-lg font-semibold text-gray-900">Open Positions</h2>
            </div>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Symbol</th>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Side</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Quantity</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Entry</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Current</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">P&L</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">P&L %</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Duration</th>
                  </tr>
                </thead>
                <tbody class="bg-white divide-y divide-gray-200">
                  <%= for position <- @open_positions do %>
                    <tr>
                      <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">
                        <%= position.symbol %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm">
                        <span class={side_badge_class(position.side)}>
                          <%= String.upcase(position.side) %>
                        </span>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-right text-gray-900">
                        <%= position.quantity %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-right text-gray-900">
                        $<%= format_price(position.entry_price) %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-right text-gray-900">
                        $<%= format_price(position.current_price) %>
                      </td>
                      <td class={"px-6 py-4 whitespace-nowrap text-sm text-right font-semibold #{pnl_class(Decimal.to_float(position.pnl))}"}>
                        $<%= format_decimal(position.pnl) %>
                      </td>
                      <td class={"px-6 py-4 whitespace-nowrap text-sm text-right font-semibold #{pnl_class(Decimal.to_float(position.pnl_percent))}"}>
                        <%= format_decimal(position.pnl_percent) %>%
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-right text-gray-500">
                        <%= format_duration(position.opened_at) %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>

        <!-- Recent Trades -->
        <div class="bg-white shadow rounded-lg">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-lg font-semibold text-gray-900">Recent Trades</h2>
          </div>
          <%= if Enum.empty?(@trades) do %>
            <div class="text-center py-12 text-gray-500">
              <p>No trades yet</p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Time</th>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Symbol</th>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Side</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Quantity</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Price</th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">P&L</th>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Order ID</th>
                  </tr>
                </thead>
                <tbody class="bg-white divide-y divide-gray-200">
                  <%= for trade <- @trades do %>
                    <tr>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                        <%= format_datetime(trade.executed_at) %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">
                        <%= trade.symbol %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm">
                        <span class={side_badge_class(trade.side)}>
                          <%= String.upcase(trade.side) %>
                        </span>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-right text-gray-900">
                        <%= trade.quantity %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-right text-gray-900">
                        $<%= format_price(trade.price) %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-right">
                        <%= if trade.pnl do %>
                          <span class={"font-semibold #{pnl_class(Decimal.to_float(trade.pnl))}"}>
                            $<%= format_decimal(trade.pnl) %>
                          </span>
                        <% else %>
                          <span class="text-gray-400">-</span>
                        <% end %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500 font-mono">
                        <%= trade.order_id %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp status_badge_class("active"), do: "px-3 py-1 text-sm font-semibold rounded-full bg-green-100 text-green-800"
  defp status_badge_class("paused"), do: "px-3 py-1 text-sm font-semibold rounded-full bg-yellow-100 text-yellow-800"
  defp status_badge_class("stopped"), do: "px-3 py-1 text-sm font-semibold rounded-full bg-gray-100 text-gray-800"
  defp status_badge_class(_), do: "px-3 py-1 text-sm font-semibold rounded-full bg-gray-100 text-gray-800"

  defp side_badge_class("buy"), do: "px-2 py-1 text-xs font-semibold rounded bg-green-100 text-green-800"
  defp side_badge_class("sell"), do: "px-2 py-1 text-xs font-semibold rounded bg-red-100 text-red-800"
  defp side_badge_class(_), do: "px-2 py-1 text-xs font-semibold rounded bg-gray-100 text-gray-800"

  defp pnl_class(pnl) when pnl > 0, do: "text-green-600"
  defp pnl_class(pnl) when pnl < 0, do: "text-red-600"
  defp pnl_class(_), do: "text-gray-600"

  defp format_percent(num), do: "#{:erlang.float_to_binary(num * 1.0, decimals: 1)}%"
  defp format_number(num), do: :erlang.float_to_binary(num * 1.0, decimals: 2)

  defp format_price(nil), do: "N/A"
  defp format_price(price) when is_struct(price, Decimal), do: Decimal.to_string(price)
  defp format_price(price) when is_number(price), do: :erlang.float_to_binary(price * 1.0, decimals: 2)

  defp format_decimal(nil), do: "0.00"
  defp format_decimal(decimal) when is_struct(decimal, Decimal), do: Decimal.to_string(decimal)
  defp format_decimal(num) when is_number(num), do: :erlang.float_to_binary(num * 1.0, decimals: 2)

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  defp format_duration(nil), do: "N/A"

  defp format_duration(opened_at) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, opened_at, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86400)}d"
    end
  end

  defp format_strategy_type("rsi_mean_reversion"), do: "RSI Mean Reversion"
  defp format_strategy_type("ma_crossover"), do: "MA Crossover"
  defp format_strategy_type(type), do: type

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 5 -> "Just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp get_runtime_status(strategy_id, _symbol) do
    # Check if the strategy runner process is alive
    running = SofiTrader.Strategies.Supervisor.strategy_running?(strategy_id)

    # Get data source mode (polling or websocket)
    data_source = get_data_source_mode()

    if running do
      # Try to get the runner state
      try do
        state = SofiTrader.Strategies.Runner.get_state(strategy_id)
        timeframe = state.strategy.config["timeframe"] || "5min"
        price_history_count = length(state.price_history)
        current_price = List.last(state.price_history)

        %{
          running: true,
          timeframe: timeframe,
          price_history_count: price_history_count,
          current_price: current_price,
          data_source: data_source
        }
      rescue
        _ ->
          %{
            running: true,
            timeframe: "Unknown",
            price_history_count: 0,
            current_price: nil,
            data_source: data_source
          }
      end
    else
      %{
        running: false,
        timeframe: "N/A",
        price_history_count: 0,
        current_price: nil,
        data_source: data_source
      }
    end
  end

  defp get_data_source_mode do
    # Check if we're in sandbox mode
    config = Application.get_env(:sofi_trader, :tradier, [])
    sandbox = Keyword.get(config, :sandbox, true)

    if sandbox, do: "polling", else: "websocket"
  end

  defp get_dashboard_data(strategy_id, strategy) do
    # Check if the strategy runner process is running
    running = SofiTrader.Strategies.Supervisor.strategy_running?(strategy_id)

    if running do
      try do
        # Get the current state from the strategy runner
        state = SofiTrader.Strategies.Runner.get_state(strategy_id)
        price_history = state.price_history

        # Get config values and parse as integers (they're stored as strings in DB)
        config = strategy.config
        rsi_period = parse_int(Map.get(config, "rsi_period", "14"), 14)
        oversold_threshold = parse_int(Map.get(config, "oversold_threshold", "30"), 30)
        overbought_threshold = parse_int(Map.get(config, "overbought_threshold", "70"), 70)

        # Calculate RSI if we have enough data
        {rsi, signal_strength, signal_type} =
          if length(price_history) >= rsi_period + 1 do
            case SofiTrader.Indicators.calculate_rsi(price_history, rsi_period) do
              {:ok, rsi_value} ->
                # Determine signal type and strength
                cond do
                  rsi_value < oversold_threshold ->
                    strength = SofiTrader.Strategies.Implementations.RsiMeanReversion.calculate_signal_strength(
                      rsi_value, oversold_threshold, :oversold
                    )
                    {rsi_value, strength, :buy}

                  rsi_value > overbought_threshold ->
                    strength = SofiTrader.Strategies.Implementations.RsiMeanReversion.calculate_signal_strength(
                      rsi_value, overbought_threshold, :overbought
                    )
                    {rsi_value, strength, :sell}

                  true ->
                    {rsi_value, 0.0, :neutral}
                end

              {:error, _} -> {nil, 0.0, :neutral}
            end
          else
            {nil, 0.0, :neutral}
          end

        # Check entry conditions
        current_price = List.last(price_history)
        has_open_positions = length(Strategies.list_open_positions(strategy_id)) > 0

        # Check risk management
        {can_trade, risk_message} =
          if rsi && signal_type == :buy && !has_open_positions && current_price do
            case SofiTrader.RiskManager.can_open_position?(strategy, strategy.symbol, current_price) do
              {:ok, _risk_details} -> {true, "All checks passed"}
              {:error, reason} -> {false, format_risk_error(reason)}
            end
          else
            {false, "Waiting for signal"}
          end

        # Capital is always available (strategy doesn't track capital_allocation separately)
        conditions = %{
          rsi_signal: signal_type == :buy,
          rsi_value: rsi,
          no_open_positions: !has_open_positions,
          capital_available: true,
          risk_checks: can_trade
        }

        %{
          rsi: rsi,
          signal_strength: signal_strength,
          signal_type: signal_type,
          current_price: current_price,
          oversold_threshold: oversold_threshold,
          overbought_threshold: overbought_threshold,
          rsi_period: rsi_period,
          conditions: conditions,
          can_trade: can_trade,
          risk_message: risk_message,
          has_data: true
        }
      rescue
        e ->
          %{
            rsi: nil,
            signal_strength: 0.0,
            signal_type: :neutral,
            current_price: nil,
            oversold_threshold: 30,
            overbought_threshold: 70,
            rsi_period: 14,
            conditions: %{
              rsi_signal: false,
              rsi_value: nil,
              no_open_positions: true,
              capital_available: true,
              risk_checks: false
            },
            can_trade: false,
            risk_message: "Error: #{inspect(e)}",
            has_data: false
          }
      end
    else
      # Strategy not running
      config = strategy.config
      %{
        rsi: nil,
        signal_strength: 0.0,
        signal_type: :neutral,
        current_price: nil,
        oversold_threshold: parse_int(Map.get(config, "oversold_threshold", "30"), 30),
        overbought_threshold: parse_int(Map.get(config, "overbought_threshold", "70"), 70),
        rsi_period: parse_int(Map.get(config, "rsi_period", "14"), 14),
        conditions: %{
          rsi_signal: false,
          rsi_value: nil,
          no_open_positions: true,
          capital_available: true,
          risk_checks: false
        },
        can_trade: false,
        risk_message: "Strategy not running",
        has_data: false
      }
    end
  end

  defp format_risk_error(:max_positions_reached), do: "Max positions reached"
  defp format_risk_error(:insufficient_capital), do: "Insufficient capital"
  defp format_risk_error(:position_size_too_small), do: "Position size too small"
  defp format_risk_error(reason), do: inspect(reason)

  # Dashboard UI helper functions
  defp rsi_color(rsi, oversold, overbought) do
    cond do
      rsi < oversold -> "#dc2626"  # red-600 (oversold - buy signal)
      rsi > overbought -> "#dc2626"  # red-600 (overbought - sell signal)
      true -> "#059669"  # green-600 (neutral)
    end
  end

  defp signal_strength_color(strength) do
    cond do
      strength >= 75 -> "#dc2626"  # red-600
      strength >= 50 -> "#f59e0b"  # amber-500
      strength >= 25 -> "#fbbf24"  # yellow-400
      true -> "#9ca3af"  # gray-400
    end
  end

  defp signal_type_label(:buy), do: "BUY SIGNAL"
  defp signal_type_label(:sell), do: "SELL SIGNAL"
  defp signal_type_label(:neutral), do: "NEUTRAL"

  # Parse string or integer to integer, with fallback
  defp parse_int(value, default) when is_integer(value), do: value
  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end
  defp parse_int(_, default), do: default
end
