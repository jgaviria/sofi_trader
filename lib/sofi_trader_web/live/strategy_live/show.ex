defmodule SofiTraderWeb.StrategyLive.Show do
  use SofiTraderWeb, :live_view

  alias SofiTrader.Strategies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    strategy = Strategies.get_strategy_with_positions!(id)

    if connected?(socket) do
      # Subscribe to strategy updates
      Phoenix.PubSub.subscribe(SofiTrader.PubSub, "strategy:#{id}")
      # Refresh data every 2 seconds
      :timer.send_interval(2000, self(), :refresh_data)
    end

    socket =
      socket
      |> assign(:strategy, strategy)
      |> assign(:positions, Strategies.list_positions(strategy.id))
      |> assign(:open_positions, Strategies.list_open_positions(strategy.id))
      |> assign(:trades, Strategies.list_trades(strategy.id, 50))

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
end
