defmodule SofiTraderWeb.KalshiLive.Markets do
  @moduledoc """
  LiveView for browsing Kalshi markets.
  """

  use SofiTraderWeb, :live_view

  alias SofiTrader.Kalshi.Markets

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Kalshi Markets")
      |> assign(:markets, [])
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:search, "")
      |> assign(:status_filter, "open")
      |> assign(:api_configured, api_configured?())

    if connected?(socket) && api_configured?() do
      send(self(), :load_markets)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_markets, socket) do
    case Markets.list_markets(status: socket.assigns.status_filter, limit: 100) do
      {:ok, %{"markets" => markets}} ->
        {:noreply, assign(socket, markets: markets, loading: false)}

      {:ok, markets} when is_list(markets) ->
        {:noreply, assign(socket, markets: markets, loading: false)}

      {:error, reason} ->
        {:noreply, assign(socket, error: inspect(reason), loading: false)}
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, search: search)}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    socket =
      socket
      |> assign(:status_filter, status)
      |> assign(:loading, true)

    send(self(), :load_markets)
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    socket = assign(socket, :loading, true)
    send(self(), :load_markets)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Header -->
        <div class="mb-6 flex justify-between items-center">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">Kalshi Markets</h1>
            <p class="mt-2 text-sm text-gray-600">
              Browse and select markets for your strategies
            </p>
          </div>
          <.link
            navigate={~p"/kalshi"}
            class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50"
          >
            ← Back to Strategies
          </.link>
        </div>

        <%= unless @api_configured do %>
          <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-6 text-center">
            <svg class="h-12 w-12 text-yellow-600 mx-auto mb-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
            </svg>
            <h3 class="text-lg font-semibold text-yellow-800 mb-2">API Not Configured</h3>
            <p class="text-yellow-700">
              Set <code class="bg-yellow-100 px-1 rounded">KALSHI_API_KEY</code> and <code class="bg-yellow-100 px-1 rounded">KALSHI_PRIVATE_KEY</code> to browse markets.
            </p>
          </div>
        <% else %>
          <!-- Filters -->
          <div class="mb-6 flex gap-4 items-center">
            <div class="flex-1">
              <input
                type="text"
                placeholder="Search markets..."
                value={@search}
                phx-keyup="search"
                phx-debounce="300"
                class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
              />
            </div>

            <div class="flex gap-2">
              <button
                phx-click="filter_status"
                phx-value-status="open"
                class={"px-4 py-2 text-sm font-medium rounded-md #{if @status_filter == "open", do: "bg-indigo-600 text-white", else: "bg-white text-gray-700 border border-gray-300 hover:bg-gray-50"}"}
              >
                Open
              </button>
              <button
                phx-click="filter_status"
                phx-value-status="unopened"
                class={"px-4 py-2 text-sm font-medium rounded-md #{if @status_filter == "unopened", do: "bg-indigo-600 text-white", else: "bg-white text-gray-700 border border-gray-300 hover:bg-gray-50"}"}
              >
                Upcoming
              </button>
              <button
                phx-click="filter_status"
                phx-value-status="closed"
                class={"px-4 py-2 text-sm font-medium rounded-md #{if @status_filter == "closed", do: "bg-indigo-600 text-white", else: "bg-white text-gray-700 border border-gray-300 hover:bg-gray-50"}"}
              >
                Closed
              </button>
            </div>

            <button
              phx-click="refresh"
              class="p-2 text-gray-500 hover:text-gray-700"
              title="Refresh"
            >
              <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
              </svg>
            </button>
          </div>

          <!-- Loading State -->
          <%= if @loading do %>
            <div class="text-center py-12">
              <div class="animate-spin rounded-full h-12 w-12 border-b-2 border-indigo-600 mx-auto"></div>
              <p class="mt-4 text-gray-600">Loading markets...</p>
            </div>
          <% end %>

          <!-- Error State -->
          <%= if @error do %>
            <div class="bg-red-50 border border-red-200 rounded-lg p-4 text-red-800">
              <p class="font-semibold">Error loading markets</p>
              <p class="text-sm mt-1"><%= @error %></p>
            </div>
          <% end %>

          <!-- Markets Grid -->
          <%= unless @loading or @error do %>
            <%= if Enum.empty?(filtered_markets(@markets, @search)) do %>
              <div class="text-center py-12 text-gray-500">
                <p>No markets found matching your criteria.</p>
              </div>
            <% else %>
              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <%= for market <- filtered_markets(@markets, @search) do %>
                  <.market_card market={market} />
                <% end %>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp market_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow hover:shadow-lg transition-shadow p-4">
      <div class="flex justify-between items-start mb-3">
        <h3 class="text-sm font-semibold text-gray-900 line-clamp-2">
          <%= @market["title"] || @market["ticker"] %>
        </h3>
        <span class={status_badge(@market["status"])}>
          <%= @market["status"] %>
        </span>
      </div>

      <div class="text-xs text-gray-500 mb-3">
        <code class="bg-gray-100 px-1 rounded"><%= @market["ticker"] %></code>
      </div>

      <!-- Prices -->
      <div class="grid grid-cols-2 gap-2 mb-3">
        <div class="bg-green-50 rounded p-2 text-center">
          <div class="text-xs text-green-600 font-medium">YES</div>
          <div class="text-lg font-bold text-green-700">
            <%= format_price(@market["yes_bid"]) %>¢
          </div>
        </div>
        <div class="bg-red-50 rounded p-2 text-center">
          <div class="text-xs text-red-600 font-medium">NO</div>
          <div class="text-lg font-bold text-red-700">
            <%= format_price(@market["no_bid"]) %>¢
          </div>
        </div>
      </div>

      <!-- Volume -->
      <div class="flex justify-between text-xs text-gray-500 mb-3">
        <span>Volume: <%= format_volume(@market["volume"]) %></span>
        <span>OI: <%= format_volume(@market["open_interest"]) %></span>
      </div>

      <!-- Action -->
      <.link
        navigate={~p"/kalshi/new?market_ticker=#{@market["ticker"]}"}
        class="block w-full text-center px-3 py-2 text-sm font-medium rounded-md text-indigo-600 bg-indigo-50 hover:bg-indigo-100"
      >
        Create Strategy
      </.link>
    </div>
    """
  end

  # Helpers

  defp api_configured?, do: SofiTrader.Kalshi.Client.configured?()

  defp filtered_markets(markets, "") when is_list(markets), do: markets
  defp filtered_markets(markets, search) when is_list(markets) do
    search_lower = String.downcase(search)

    Enum.filter(markets, fn market ->
      title = String.downcase(market["title"] || "")
      ticker = String.downcase(market["ticker"] || "")

      String.contains?(title, search_lower) || String.contains?(ticker, search_lower)
    end)
  end
  defp filtered_markets(_, _), do: []

  defp status_badge("open"), do: "px-2 py-0.5 text-xs font-medium rounded-full bg-green-100 text-green-800"
  defp status_badge("unopened"), do: "px-2 py-0.5 text-xs font-medium rounded-full bg-blue-100 text-blue-800"
  defp status_badge("closed"), do: "px-2 py-0.5 text-xs font-medium rounded-full bg-gray-100 text-gray-800"
  defp status_badge(_), do: "px-2 py-0.5 text-xs font-medium rounded-full bg-gray-100 text-gray-800"

  defp format_price(nil), do: "--"
  defp format_price(price) when is_integer(price), do: price
  defp format_price(price) when is_float(price), do: round(price * 100)
  defp format_price(_), do: "--"

  defp format_volume(nil), do: "0"
  defp format_volume(vol) when vol >= 1_000_000, do: "#{Float.round(vol / 1_000_000, 1)}M"
  defp format_volume(vol) when vol >= 1_000, do: "#{Float.round(vol / 1_000, 1)}K"
  defp format_volume(vol), do: to_string(vol)
end
