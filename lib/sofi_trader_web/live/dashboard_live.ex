defmodule SofiTraderWeb.DashboardLive do
  use SofiTraderWeb, :live_view

  alias SofiTrader.Tradier.MarketData

  @default_symbols ["AAPL", "MSFT", "GOOGL", "TSLA", "NVDA"]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:symbols, @default_symbols)
      |> assign(:quotes, %{})
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:token_configured, token_configured?())
      |> assign(:show_trade_modal, false)
      |> assign(:trade_symbol, nil)
      |> assign(:trade_side, nil)
      |> assign(:success_message, nil)

    # Only fetch quotes if token is configured
    if socket.assigns.token_configured do
      send(self(), :fetch_quotes)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:fetch_quotes, socket) do
    case fetch_market_quotes(socket.assigns.symbols) do
      {:ok, quotes} ->
        socket =
          socket
          |> assign(:quotes, quotes)
          |> assign(:loading, false)
          |> assign(:error, nil)

        # Schedule next update in 5 seconds
        Process.send_after(self(), :fetch_quotes, 5_000)

        {:noreply, socket}

      {:error, error} ->
        {:noreply, assign(socket, error: format_error(error), loading: false)}
    end
  end

  @impl true
  def handle_info({:order_placed, symbol, order_id, side}, socket) do
    action = if side == :buy, do: "Buy", else: "Sell"
    message = "#{action} order placed successfully for #{symbol}. Order ID: #{order_id}"

    socket =
      socket
      |> assign(:show_trade_modal, false)
      |> assign(:success_message, message)

    # Clear success message after 5 seconds
    Process.send_after(self(), :clear_success, 5_000)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:clear_success, socket) do
    {:noreply, assign(socket, :success_message, nil)}
  end

  @impl true
  def handle_info({:close_modal}, socket) do
    {:noreply, assign(socket, show_trade_modal: false)}
  end

  @impl true
  def handle_event("add_symbol", %{"symbol" => symbol}, socket) do
    symbol = String.upcase(String.trim(symbol))

    if symbol != "" and symbol not in socket.assigns.symbols do
      new_symbols = [symbol | socket.assigns.symbols]
      send(self(), :fetch_quotes)
      {:noreply, assign(socket, :symbols, new_symbols)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_symbol", %{"symbol" => symbol}, socket) do
    new_symbols = List.delete(socket.assigns.symbols, symbol)
    quotes = Map.delete(socket.assigns.quotes, symbol)

    {:noreply, assign(socket, symbols: new_symbols, quotes: quotes)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    send(self(), :fetch_quotes)
    {:noreply, assign(socket, :loading, true)}
  end

  @impl true
  def handle_event("open_trade", %{"symbol" => symbol, "side" => side}, socket) do
    trade_side = String.to_atom(side)
    {:noreply, assign(socket, show_trade_modal: true, trade_symbol: symbol, trade_side: trade_side)}
  end

  @impl true
  def handle_event("close_trade_modal", _params, socket) do
    {:noreply, assign(socket, show_trade_modal: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8 flex justify-between items-center">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">SofiTrader Dashboard</h1>
            <p class="mt-2 text-sm text-gray-600">Real-time market data powered by Tradier API</p>
          </div>
          <.link
            navigate={~p"/strategies"}
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
          >
            <svg class="h-5 w-5 mr-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
            </svg>
            Trading Strategies
          </.link>
        </div>

        <%= if !@token_configured do %>
          <div class="rounded-md bg-yellow-50 p-4 mb-6">
            <div class="flex">
              <div class="flex-shrink-0">
                <svg class="h-5 w-5 text-yellow-400" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd" />
                </svg>
              </div>
              <div class="ml-3">
                <h3 class="text-sm font-medium text-yellow-800">Tradier API Token Not Configured</h3>
                <div class="mt-2 text-sm text-yellow-700">
                  <p>Set your Tradier API token to enable live market data:</p>
                  <code class="block mt-2 bg-yellow-100 p-2 rounded">
                    export TRADIER_ACCESS_TOKEN="your_token_here"
                  </code>
                  <p class="mt-2">Then restart the server.</p>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%= if @success_message do %>
          <div class="rounded-md bg-green-50 p-4 mb-6">
            <div class="flex">
              <div class="flex-shrink-0">
                <svg class="h-5 w-5 text-green-400" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
                </svg>
              </div>
              <div class="ml-3">
                <h3 class="text-sm font-medium text-green-800">Success!</h3>
                <div class="mt-2 text-sm text-green-700">
                  <p><%= @success_message %></p>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%= if @error do %>
          <div class="rounded-md bg-red-50 p-4 mb-6">
            <div class="flex">
              <div class="ml-3">
                <h3 class="text-sm font-medium text-red-800">Error fetching market data</h3>
                <div class="mt-2 text-sm text-red-700">
                  <p><%= @error %></p>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Add Symbol Form -->
        <div class="bg-white shadow rounded-lg p-6 mb-6">
          <form phx-submit="add_symbol" class="flex gap-4">
            <input
              type="text"
              name="symbol"
              placeholder="Enter symbol (e.g., AAPL)"
              class="flex-1 rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
            />
            <button
              type="submit"
              class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
            >
              Add Symbol
            </button>
            <button
              type="button"
              phx-click="refresh"
              class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md shadow-sm text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
            >
              Refresh
            </button>
          </form>
        </div>

        <!-- Market Quotes -->
        <%= if @loading and map_size(@quotes) == 0 do %>
          <div class="text-center py-12">
            <div class="inline-block animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600"></div>
            <p class="mt-4 text-gray-600">Loading market data...</p>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            <%= for symbol <- @symbols do %>
              <div class="bg-white shadow rounded-lg p-6 hover:shadow-lg transition-shadow">
                <div class="flex justify-between items-start mb-4">
                  <h3 class="text-xl font-bold text-gray-900"><%= symbol %></h3>
                  <button
                    phx-click="remove_symbol"
                    phx-value-symbol={symbol}
                    class="text-gray-400 hover:text-red-600"
                  >
                    <svg class="h-5 w-5" fill="currentColor" viewBox="0 0 20 20">
                      <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
                    </svg>
                  </button>
                </div>

                <%= if quote = Map.get(@quotes, symbol) do %>
                  <div class="space-y-2">
                    <div class="flex justify-between items-baseline">
                      <span class="text-3xl font-bold text-gray-900">
                        $<%= format_price(quote["last"]) %>
                      </span>
                      <span class={"text-sm font-medium #{price_change_color(quote["change"])}"}>
                        <%= format_change(quote["change"]) %> (<%= format_percent(quote["change_percentage"]) %>)
                      </span>
                    </div>

                    <div class="grid grid-cols-2 gap-4 pt-4 border-t border-gray-200 text-sm">
                      <div>
                        <span class="text-gray-500">High</span>
                        <div class="font-semibold">$<%= format_price(quote["high"]) %></div>
                      </div>
                      <div>
                        <span class="text-gray-500">Low</span>
                        <div class="font-semibold">$<%= format_price(quote["low"]) %></div>
                      </div>
                      <div>
                        <span class="text-gray-500">Volume</span>
                        <div class="font-semibold"><%= format_volume(quote["volume"]) %></div>
                      </div>
                      <div>
                        <span class="text-gray-500">Bid/Ask</span>
                        <div class="font-semibold">
                          <%= format_price(quote["bid"]) %>/<%= format_price(quote["ask"]) %>
                        </div>
                      </div>
                    </div>

                    <!-- Trading Buttons -->
                    <div class="flex gap-2 mt-4 pt-4 border-t border-gray-200">
                      <button
                        phx-click="open_trade"
                        phx-value-symbol={symbol}
                        phx-value-side="buy"
                        class="flex-1 inline-flex justify-center items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-emerald-500 hover:bg-emerald-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-emerald-400"
                      >
                        Buy
                      </button>
                      <button
                        phx-click="open_trade"
                        phx-value-symbol={symbol}
                        phx-value-side="sell"
                        class="flex-1 inline-flex justify-center items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-rose-500 hover:bg-rose-600 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-rose-400"
                      >
                        Sell
                      </button>
                    </div>
                  </div>
                <% else %>
                  <div class="text-center py-4 text-gray-500">
                    <div class="inline-block animate-spin rounded-full h-6 w-6 border-b-2 border-blue-600"></div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="mt-8 text-center text-sm text-gray-500">
          <p>Data updates every 5 seconds</p>
          <p class="mt-1">Using Tradier <%= if System.get_env("TRADIER_SANDBOX") == "true", do: "Sandbox", else: "Production" %> API</p>
        </div>
      </div>

      <!-- Trade Modal -->
      <%= if @show_trade_modal && @trade_symbol && @trade_side do %>
        <.live_component
          module={SofiTraderWeb.Components.TradeModal}
          id="trade-modal"
          symbol={@trade_symbol}
          side={@trade_side}
          current_price={get_current_price(@quotes, @trade_symbol)}
        />
      <% end %>
    </div>
    """
  end

  defp fetch_market_quotes(symbols) do
    case MarketData.get_quotes(symbols) do
      {:ok, %{"quotes" => %{"quote" => quotes}}} when is_list(quotes) ->
        quote_map = Map.new(quotes, fn q -> {q["symbol"], q} end)
        {:ok, quote_map}

      {:ok, %{"quotes" => %{"quote" => quote}}} when is_map(quote) ->
        {:ok, %{quote["symbol"] => quote}}

      {:ok, response} ->
        {:error, "Unexpected response format: #{inspect(response)}"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp token_configured? do
    System.get_env("TRADIER_ACCESS_TOKEN") != nil
  end

  defp format_price(nil), do: "N/A"
  defp format_price(price) when is_number(price), do: :erlang.float_to_binary(price * 1.0, decimals: 2)
  defp format_price(price) when is_binary(price), do: price

  defp format_change(nil), do: "N/A"
  defp format_change(change) when is_number(change) do
    sign = if change >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(change * 1.0, decimals: 2)}"
  end

  defp format_percent(nil), do: "N/A"
  defp format_percent(pct) when is_number(pct) do
    sign = if pct >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(pct * 1.0, decimals: 2)}%"
  end

  defp format_volume(nil), do: "N/A"
  defp format_volume(volume) when is_number(volume) do
    cond do
      volume >= 1_000_000 -> "#{Float.round(volume / 1_000_000, 1)}M"
      volume >= 1_000 -> "#{Float.round(volume / 1_000, 1)}K"
      true -> to_string(volume)
    end
  end

  defp price_change_color(change) when is_number(change) do
    if change >= 0, do: "text-green-600", else: "text-red-600"
  end
  defp price_change_color(_), do: "text-gray-600"

  defp format_error(%{body: body}) when is_map(body), do: inspect(body)
  defp format_error(%{status: status}), do: "HTTP #{status}"
  defp format_error(error), do: inspect(error)

  defp get_current_price(quotes, symbol) do
    case Map.get(quotes, symbol) do
      nil -> 0.0
      quote -> quote["last"] || quote["close"] || 0.0
    end
  end
end
