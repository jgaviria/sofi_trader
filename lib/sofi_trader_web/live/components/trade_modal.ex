defmodule SofiTraderWeb.Components.TradeModal do
  @moduledoc """
  Live component for placing trade orders.

  Supports market and limit orders with order preview and confirmation.
  """

  use SofiTraderWeb, :live_component

  alias SofiTrader.Tradier.{Trading, Accounts}

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:order_type, fn -> "market" end)
      |> assign_new(:duration, fn -> "day" end)
      |> assign_new(:quantity, fn -> 10 end)
      |> assign_new(:limit_price, fn -> nil end)
      |> assign_new(:order_preview, fn -> nil end)
      |> assign_new(:submitting, fn -> false end)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:buying_power, fn -> fetch_buying_power(assigns) end)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_quantity", %{"value" => quantity}, socket) do
    {qty, _} = Integer.parse(quantity)
    {:noreply, assign(socket, quantity: qty, order_preview: nil)}
  end

  @impl true
  def handle_event("update_order_type", %{"value" => order_type}, socket) do
    {:noreply, assign(socket, order_type: order_type, order_preview: nil)}
  end

  @impl true
  def handle_event("update_duration", %{"value" => duration}, socket) do
    {:noreply, assign(socket, duration: duration, order_preview: nil)}
  end

  @impl true
  def handle_event("update_limit_price", %{"value" => price}, socket) do
    limit_price = case Float.parse(price) do
      {p, _} -> p
      :error -> nil
    end
    {:noreply, assign(socket, limit_price: limit_price, order_preview: nil)}
  end

  @impl true
  def handle_event("preview_order", _params, socket) do
    preview = generate_preview(socket.assigns)
    {:noreply, assign(socket, order_preview: preview, error: nil)}
  end

  @impl true
  def handle_event("place_order", _params, socket) do
    socket = assign(socket, submitting: true, error: nil)

    order_params = build_order_params(socket.assigns)
    account_id = get_account_id()
    token = get_token()

    case Trading.place_order(account_id, order_params, token: token) do
      {:ok, response} ->
        order_id = get_in(response, ["order", "id"])

        # Notify parent
        send(self(), {:order_placed, socket.assigns.symbol, order_id, socket.assigns.side})

        {:noreply,
         socket
         |> assign(submitting: false)
         |> push_event("close-modal", %{})}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(submitting: false, error: format_error(error))}
    end
  end

  @impl true
  def handle_event("close", _params, socket) do
    send(self(), {:close_modal})
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 flex items-center justify-center p-4 z-50" style="background-color: rgba(0, 0, 0, 0.3); backdrop-filter: blur(2px);" phx-click="close" phx-target={@myself}>
      <div class="bg-white rounded-lg shadow-xl max-w-2xl w-full p-6" phx-click="stop_propagation" phx-target={@myself}>
        <!-- Header -->
        <div class="flex justify-between items-start mb-6">
          <div>
            <h3 class="text-2xl font-bold text-gray-900">
              <%= if @side == :buy, do: "Buy", else: "Sell" %> <%= @symbol %>
            </h3>
            <p class="text-sm text-gray-500 mt-1">
              Current Price: $<%= @current_price %>
            </p>
          </div>
          <button phx-click="close" phx-target={@myself} class="text-gray-400 hover:text-gray-500">
            <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <%= if @error do %>
          <div class="mb-4 rounded-md bg-red-50 p-4">
            <div class="flex">
              <div class="ml-3">
                <h3 class="text-sm font-medium text-red-800">Error placing order</h3>
                <div class="mt-2 text-sm text-red-700"><%= @error %></div>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Order Form -->
        <div class="space-y-4 mb-6">
          <!-- Quantity -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">Quantity</label>
            <input
              type="number"
              value={@quantity}
              phx-change="update_quantity"
              phx-target={@myself}
              min="1"
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
            />
          </div>

          <!-- Order Type -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">Order Type</label>
            <select
              phx-change="update_order_type"
              phx-target={@myself}
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
            >
              <option value="market" selected={@order_type == "market"}>Market</option>
              <option value="limit" selected={@order_type == "limit"}>Limit</option>
            </select>
          </div>

          <%= if @order_type == "limit" do %>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Limit Price</label>
              <input
                type="number"
                step="0.01"
                value={@limit_price}
                phx-change="update_limit_price"
                phx-target={@myself}
                placeholder="Enter limit price"
                class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
              />
            </div>
          <% end %>

          <!-- Duration -->
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">Duration</label>
            <select
              phx-change="update_duration"
              phx-target={@myself}
              class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
            >
              <option value="day" selected={@duration == "day"}>Day</option>
              <option value="gtc" selected={@duration == "gtc"}>Good 'til Canceled (GTC)</option>
            </select>
          </div>
        </div>

        <!-- Order Preview -->
        <%= if @order_preview do %>
          <div class="mb-6 rounded-lg bg-blue-50 p-4 border border-blue-200">
            <h4 class="font-semibold text-blue-900 mb-3">Order Preview</h4>
            <dl class="space-y-2 text-sm">
              <div class="flex justify-between">
                <dt class="text-blue-700">Action:</dt>
                <dd class="font-medium text-blue-900"><%= @order_preview.action %></dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-blue-700">Quantity:</dt>
                <dd class="font-medium text-blue-900"><%= @order_preview.quantity %> shares</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-blue-700">Order Type:</dt>
                <dd class="font-medium text-blue-900"><%= @order_preview.type %></dd>
              </div>
              <%= if @order_preview.price do %>
                <div class="flex justify-between">
                  <dt class="text-blue-700">Price:</dt>
                  <dd class="font-medium text-blue-900">$<%= @order_preview.price %></dd>
                </div>
              <% end %>
              <div class="flex justify-between border-t border-blue-300 pt-2 mt-2">
                <dt class="font-semibold text-blue-900">Est. Total:</dt>
                <dd class="font-bold text-blue-900">$<%= @order_preview.estimated_total %></dd>
              </div>
            </dl>
          </div>
        <% end %>

        <!-- Account Info -->
        <%= if @buying_power do %>
          <div class="mb-6 text-sm text-gray-600">
            <p>Available Buying Power: <span class="font-semibold">$<%= format_money(@buying_power) %></span></p>
          </div>
        <% end %>

        <!-- Actions -->
        <div class="flex gap-3">
          <%= if @order_preview do %>
            <button
              phx-click="place_order"
              phx-target={@myself}
              disabled={@submitting}
              class={"flex-1 inline-flex justify-center items-center px-4 py-3 border border-transparent text-base font-medium rounded-md text-white #{if @side == :buy, do: "bg-emerald-500 hover:bg-emerald-600", else: "bg-rose-500 hover:bg-rose-600"} focus:outline-none focus:ring-2 focus:ring-offset-2 #{if @side == :buy, do: "focus:ring-emerald-400", else: "focus:ring-rose-400"} disabled:opacity-50"}
            >
              <%= if @submitting do %>
                <svg class="animate-spin -ml-1 mr-3 h-5 w-5 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
                Placing Order...
              <% else %>
                Confirm Order
              <% end %>
            </button>
          <% else %>
            <button
              phx-click="preview_order"
              phx-target={@myself}
              class={"flex-1 inline-flex justify-center items-center px-4 py-3 border border-transparent text-base font-medium rounded-md text-white #{if @side == :buy, do: "bg-emerald-500 hover:bg-emerald-600", else: "bg-rose-500 hover:bg-rose-600"} focus:outline-none focus:ring-2 focus:ring-offset-2 #{if @side == :buy, do: "focus:ring-emerald-400", else: "focus:ring-rose-400"}"}
            >
              Preview Order
            </button>
          <% end %>

          <button
            phx-click="close"
            phx-target={@myself}
            class="px-4 py-3 border border-gray-300 text-base font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Private Functions

  defp fetch_buying_power(_assigns) do
    account_id = get_account_id()
    token = get_token()

    case Accounts.get_balances(account_id, token: token) do
      {:ok, %{"balances" => balances}} ->
        get_in(balances, ["option_buying_power"]) || get_in(balances, ["stock_buying_power"])

      _ ->
        nil
    end
  end

  defp generate_preview(assigns) do
    price = if assigns.order_type == "limit", do: assigns.limit_price, else: assigns.current_price
    estimated_total = if price, do: Float.round(price * assigns.quantity, 2), else: 0

    %{
      action: if(assigns.side == :buy, do: "Buy", else: "Sell"),
      quantity: assigns.quantity,
      type: String.capitalize(assigns.order_type),
      price: if(assigns.order_type == "limit", do: assigns.limit_price, else: nil),
      estimated_total: estimated_total
    }
  end

  defp build_order_params(assigns) do
    side = case assigns.side do
      :buy -> "buy"
      :sell -> "sell"
    end

    params = %{
      class: "equity",
      symbol: assigns.symbol,
      side: side,
      quantity: assigns.quantity,
      type: assigns.order_type,
      duration: assigns.duration
    }

    if assigns.order_type == "limit" and assigns.limit_price do
      Map.put(params, :price, assigns.limit_price)
    else
      params
    end
  end

  defp get_account_id do
    System.get_env("TRADIER_ACCOUNT_ID") || "VA35810079"
  end

  defp get_token do
    System.get_env("TRADIER_ACCESS_TOKEN")
  end

  defp format_error(%{body: body}) when is_map(body), do: inspect(body)
  defp format_error(%{status: status}), do: "HTTP #{status}"
  defp format_error(error), do: inspect(error)

  defp format_money(amount) when is_number(amount) do
    :erlang.float_to_binary(amount * 1.0, decimals: 2)
  end
  defp format_money(_), do: "N/A"
end
