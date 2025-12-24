defmodule SofiTraderWeb.KalshiLive.Orders do
  @moduledoc """
  LiveView for viewing orders placed by a specific Kalshi strategy.
  """

  use SofiTraderWeb, :live_view

  alias SofiTrader.Kalshi.Strategies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    strategy_id = String.to_integer(id)
    strategy = Strategies.get_strategy(strategy_id)

    if strategy do
      orders = Strategies.list_orders(strategy_id, limit: 100)

      socket =
        socket
        |> assign(:strategy, strategy)
        |> assign(:orders, orders)
        |> assign(:page_title, "Orders - #{strategy.name}")

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Strategy not found")
       |> push_navigate(to: ~p"/kalshi")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Header -->
        <div class="mb-8">
          <nav class="mb-4">
            <.link navigate={~p"/kalshi"} class="text-indigo-600 hover:text-indigo-800 text-sm font-medium">
              ← Back to Strategies
            </.link>
          </nav>
          <div class="flex justify-between items-center">
            <div>
              <h1 class="text-3xl font-bold text-gray-900">Orders for <%= @strategy.name %></h1>
              <p class="mt-2 text-sm text-gray-600">
                Market: <%= @strategy.market_ticker || @strategy.event_ticker || "No market" %>
                <span class="mx-2">|</span>
                Type: <%= format_strategy_type(@strategy.type) %>
              </p>
            </div>
            <span class={status_badge_class(@strategy.status)}>
              <%= String.capitalize(@strategy.status) %>
            </span>
          </div>
        </div>

        <!-- Stats Summary -->
        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
          <.stat_card label="Total Orders" value={length(@orders)} />
          <.stat_card label="Filled" value={count_by_status(@orders, "executed")} color="green" />
          <.stat_card label="Resting" value={count_by_status(@orders, "resting")} color="yellow" />
          <.stat_card label="Canceled" value={count_by_status(@orders, "canceled")} color="red" />
        </div>

        <!-- Orders Table -->
        <div class="bg-white shadow rounded-lg overflow-hidden">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-lg font-semibold text-gray-900">Order History</h2>
          </div>

          <%= if Enum.empty?(@orders) do %>
            <div class="p-8 text-center">
              <svg class="mx-auto h-12 w-12 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
              </svg>
              <h3 class="mt-2 text-sm font-medium text-gray-900">No orders yet</h3>
              <p class="mt-1 text-sm text-gray-500">Orders placed by this strategy will appear here.</p>
            </div>
          <% else %>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Order ID
                    </th>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Market
                    </th>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Side
                    </th>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Action
                    </th>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Price
                    </th>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Qty
                    </th>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Filled
                    </th>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Status
                    </th>
                    <th scope="col" class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Placed At
                    </th>
                  </tr>
                </thead>
                <tbody class="bg-white divide-y divide-gray-200">
                  <%= for order <- @orders do %>
                    <tr class="hover:bg-gray-50">
                      <td class="px-6 py-4 whitespace-nowrap text-sm font-mono text-gray-500">
                        <%= truncate_id(order.order_id) %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                        <%= order.market_ticker %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap">
                        <span class={side_badge_class(order.side)}>
                          <%= String.upcase(order.side || "N/A") %>
                        </span>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-600">
                        <%= String.capitalize(order.action || "N/A") %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-900 font-medium">
                        <%= order.price_cents %>¢
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-600">
                        <%= order.count %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-600">
                        <%= order.filled_count || 0 %>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap">
                        <span class={order_status_badge_class(order.status)}>
                          <%= String.capitalize(order.status || "unknown") %>
                        </span>
                      </td>
                      <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                        <%= format_datetime(order.placed_at) %>
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

  # Stat Card Component
  defp stat_card(assigns) do
    color = Map.get(assigns, :color, "gray")
    assigns = assign(assigns, :color, color)

    ~H"""
    <div class="bg-white rounded-lg shadow p-6">
      <p class="text-sm font-medium text-gray-500"><%= @label %></p>
      <p class={"mt-2 text-3xl font-bold #{stat_color(@color)}"}>
        <%= @value %>
      </p>
    </div>
    """
  end

  defp stat_color("green"), do: "text-green-600"
  defp stat_color("yellow"), do: "text-yellow-600"
  defp stat_color("red"), do: "text-red-600"
  defp stat_color(_), do: "text-gray-900"

  # Helper functions
  defp count_by_status(orders, status) do
    Enum.count(orders, &(&1.status == status))
  end

  defp truncate_id(nil), do: "N/A"
  defp truncate_id(id) when is_binary(id) do
    if String.length(id) > 12 do
      String.slice(id, 0, 8) <> "..."
    else
      id
    end
  end

  defp status_badge_class("active"), do: "px-3 py-1 text-sm font-semibold rounded-full bg-green-100 text-green-800"
  defp status_badge_class("paused"), do: "px-3 py-1 text-sm font-semibold rounded-full bg-yellow-100 text-yellow-800"
  defp status_badge_class(_), do: "px-3 py-1 text-sm font-semibold rounded-full bg-gray-100 text-gray-800"

  defp side_badge_class("yes"), do: "px-2 py-1 text-xs font-semibold rounded bg-green-100 text-green-800"
  defp side_badge_class("no"), do: "px-2 py-1 text-xs font-semibold rounded bg-red-100 text-red-800"
  defp side_badge_class(_), do: "px-2 py-1 text-xs font-semibold rounded bg-gray-100 text-gray-800"

  defp order_status_badge_class("executed"), do: "px-2 py-1 text-xs font-semibold rounded bg-green-100 text-green-800"
  defp order_status_badge_class("resting"), do: "px-2 py-1 text-xs font-semibold rounded bg-yellow-100 text-yellow-800"
  defp order_status_badge_class("canceled"), do: "px-2 py-1 text-xs font-semibold rounded bg-red-100 text-red-800"
  defp order_status_badge_class("pending"), do: "px-2 py-1 text-xs font-semibold rounded bg-blue-100 text-blue-800"
  defp order_status_badge_class(_), do: "px-2 py-1 text-xs font-semibold rounded bg-gray-100 text-gray-800"

  defp format_strategy_type("odds_monitor"), do: "Odds Monitor"
  defp format_strategy_type("auto_bid"), do: "Auto Bid"
  defp format_strategy_type(type), do: type

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end
end
