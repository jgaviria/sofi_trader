defmodule SofiTraderWeb.KalshiLive.Index do
  @moduledoc """
  LiveView for managing Kalshi prediction market strategies.
  """

  use SofiTraderWeb, :live_view

  alias SofiTrader.Kalshi.{Strategies, Strategy, StrategySupervisor, WebSocketManager}

  @refresh_interval 5_000  # Refresh dashboard stats every 5 seconds

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to alerts and strategy updates
      Phoenix.PubSub.subscribe(SofiTrader.PubSub, "kalshi:alerts")
      Phoenix.PubSub.subscribe(SofiTrader.PubSub, "kalshi:fills")

      # Subscribe to ticker updates for all active strategies
      subscribe_to_strategy_tickers()

      # Start periodic refresh for dashboard stats
      :timer.send_interval(@refresh_interval, self(), :refresh_dashboard)
    end

    socket =
      socket
      |> assign(:strategies, list_strategies())
      |> assign(:alerts, list_recent_alerts())
      |> assign(:show_form, false)
      |> assign(:form_strategy, nil)
      |> assign(:api_configured, api_configured?())
      |> assign(:ws_status, get_ws_status())
      |> assign(:live_prices, %{})
      |> assign(:activity_feed, [])
      |> assign(:dashboard_stats, get_dashboard_stats())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Kalshi Strategies")
    |> assign(:show_form, false)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Kalshi Strategy")
    |> assign(:show_form, true)
    |> assign(:form_strategy, %Strategy{
      config: Strategy.default_config("odds_monitor"),
      risk_params: Strategy.default_risk_params(),
      alert_config: Strategy.default_alert_config(),
      stats: Strategy.initial_stats()
    })
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    strategy = Strategies.get_strategy(String.to_integer(id))

    socket
    |> assign(:page_title, "Edit Strategy")
    |> assign(:show_form, true)
    |> assign(:form_strategy, strategy)
  end

  # Handle real-time alerts
  @impl true
  def handle_info({:new_alert, alert}, socket) do
    # Add to alerts list
    new_alerts = [alert | Enum.take(socket.assigns.alerts, 19)]

    # Add to activity feed
    activity = %{
      type: :alert,
      message: alert.message,
      severity: alert.severity,
      timestamp: DateTime.utc_now()
    }
    new_feed = [activity | Enum.take(socket.assigns.activity_feed, 9)]

    socket =
      socket
      |> assign(:alerts, new_alerts)
      |> assign(:activity_feed, new_feed)
      |> put_flash(:info, alert.message)

    {:noreply, socket}
  end

  # Handle ticker price updates
  @impl true
  def handle_info({:ticker_update, ticker_data}, socket) do
    new_prices = Map.put(socket.assigns.live_prices, ticker_data.ticker, ticker_data)
    {:noreply, assign(socket, :live_prices, new_prices)}
  end

  # Handle fill updates
  @impl true
  def handle_info({:fill_update, fill_data}, socket) do
    activity = %{
      type: :fill,
      message: "Order filled: #{fill_data["count"]} @ #{fill_data["price"]}¢",
      severity: "info",
      timestamp: DateTime.utc_now()
    }
    new_feed = [activity | Enum.take(socket.assigns.activity_feed, 9)]

    {:noreply, assign(socket, :activity_feed, new_feed)}
  end

  # Periodic dashboard refresh
  @impl true
  def handle_info(:refresh_dashboard, socket) do
    socket =
      socket
      |> assign(:ws_status, get_ws_status())
      |> assign(:dashboard_stats, get_dashboard_stats())
      |> assign(:strategies, list_strategies())

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_strategy", %{"id" => id}, socket) do
    strategy_id = String.to_integer(id)

    case StrategySupervisor.start_strategy(strategy_id, paper_trading: true) do
      {:ok, _pid} ->
        socket =
          socket
          |> put_flash(:info, "Strategy started in paper trading mode")
          |> assign(:strategies, list_strategies())

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("stop_strategy", %{"id" => id}, socket) do
    strategy_id = String.to_integer(id)

    case StrategySupervisor.stop_strategy(strategy_id) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Strategy stopped")
          |> assign(:strategies, list_strategies())

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to stop: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_strategy", %{"id" => id}, socket) do
    strategy = Strategies.get_strategy(String.to_integer(id))

    if strategy do
      # Stop if running
      StrategySupervisor.stop_strategy(strategy.id)

      case Strategies.delete_strategy(strategy) do
        {:ok, _} ->
          socket =
            socket
            |> put_flash(:info, "Strategy deleted")
            |> assign(:strategies, list_strategies())

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete strategy")}
      end
    else
      {:noreply, put_flash(socket, :error, "Strategy not found")}
    end
  end

  @impl true
  def handle_event("save_strategy", %{"strategy" => strategy_params}, socket) do
    save_strategy(socket, socket.assigns.live_action, strategy_params)
  end

  @impl true
  def handle_event("acknowledge_alert", %{"id" => id}, socket) do
    alert = Enum.find(socket.assigns.alerts, &(&1.id == String.to_integer(id)))

    if alert do
      Strategies.acknowledge_alert(alert)
      {:noreply, assign(socket, :alerts, list_recent_alerts())}
    else
      {:noreply, socket}
    end
  end

  defp save_strategy(socket, :new, strategy_params) do
    parsed_params = parse_strategy_params(strategy_params)

    case Strategies.create_strategy(parsed_params) do
      {:ok, _strategy} ->
        socket =
          socket
          |> put_flash(:info, "Strategy created")
          |> assign(:strategies, list_strategies())
          |> push_navigate(to: ~p"/kalshi")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_errors(changeset))}
    end
  end

  defp save_strategy(socket, :edit, strategy_params) do
    strategy = socket.assigns.form_strategy
    parsed_params = parse_strategy_params(strategy_params)

    case Strategies.update_strategy(strategy, parsed_params) do
      {:ok, _strategy} ->
        socket =
          socket
          |> put_flash(:info, "Strategy updated")
          |> assign(:strategies, list_strategies())
          |> push_navigate(to: ~p"/kalshi")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_errors(changeset))}
    end
  end

  # Parse form params - convert strings to appropriate types
  defp parse_strategy_params(params) do
    config = params["config"] || %{}
    risk_params = params["risk_params"] || %{}
    alert_config = params["alert_config"] || %{}

    %{
      "name" => params["name"],
      "market_ticker" => blank_to_nil(params["market_ticker"]),
      "event_ticker" => blank_to_nil(params["event_ticker"]),
      "series_ticker" => blank_to_nil(params["series_ticker"]),
      "type" => params["type"],
      "config" => %{
        "target_side" => config["target_side"],
        "price_below" => parse_int(config["price_below"]),
        "price_above" => parse_int(config["price_above"]),
        "alert_on_change_pct" => parse_float(config["alert_on_change_pct"]),
        "volume_threshold" => parse_int(config["volume_threshold"]),
        # Auto-bid fields
        "side" => config["side"],
        "action" => config["action"],
        "target_price" => parse_int(config["target_price"]),
        "trigger_price" => parse_int(config["trigger_price"]),
        "max_contracts" => parse_int(config["max_contracts"]),
        "time_in_force" => config["time_in_force"] || "gtc",
        "enabled" => config["enabled"] == "true"
      },
      "risk_params" => %{
        "max_position_size" => parse_int(risk_params["max_position_size"]) || 100,
        "max_daily_loss_cents" => (parse_int(risk_params["max_daily_loss_cents"]) || 50) * 100,
        "max_total_exposure_cents" => parse_int(risk_params["max_total_exposure_cents"]),
        "cooldown_seconds" => parse_int(risk_params["cooldown_seconds"]) || 60
      },
      "alert_config" => %{
        "channels" => ["pubsub", "ui"],
        "webhook_url" => blank_to_nil(alert_config["webhook_url"]),
        "alert_cooldown_seconds" => parse_int(alert_config["alert_cooldown_seconds"]) || 300
      }
    }
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_float(nil), do: nil
  defp parse_float(""), do: nil
  defp parse_float(val) when is_number(val), do: val
  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {float, _} -> float
      :error -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Header -->
        <div class="mb-8 flex justify-between items-center">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">Kalshi Prediction Markets</h1>
            <p class="mt-2 text-sm text-gray-600">
              Monitor odds and automate trading on prediction markets
            </p>
          </div>
          <div class="flex gap-3">
            <.link
              navigate={~p"/kalshi/markets"}
              class="inline-flex items-center px-4 py-2 border border-gray-300 text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50"
            >
              Browse Markets
            </.link>
            <.link
              navigate={~p"/kalshi/new"}
              class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
            >
              <svg class="h-5 w-5 mr-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
              </svg>
              New Strategy
            </.link>
          </div>
        </div>

        <!-- API Status Banner -->
        <%= unless @api_configured do %>
          <div class="mb-6 bg-yellow-50 border border-yellow-200 rounded-lg p-4">
            <div class="flex items-start">
              <svg class="h-5 w-5 text-yellow-600 mt-0.5 mr-3" fill="currentColor" viewBox="0 0 20 20">
                <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/>
              </svg>
              <div class="text-sm text-yellow-800">
                <p class="font-semibold mb-1">Kalshi API Not Configured</p>
                <p>Set <code class="bg-yellow-100 px-1 rounded">KALSHI_API_KEY</code> and <code class="bg-yellow-100 px-1 rounded">KALSHI_PRIVATE_KEY</code> environment variables to enable live trading.</p>
                <p class="mt-2">You can still create strategies - they'll start when API is configured.</p>
              </div>
            </div>
          </div>
        <% end %>

        <!-- Live Dashboard Panel -->
        <.live_dashboard
          ws_status={@ws_status}
          dashboard_stats={@dashboard_stats}
          live_prices={@live_prices}
          activity_feed={@activity_feed}
        />

        <!-- Strategy Form Modal -->
        <%= if @show_form do %>
          <.strategy_form form_strategy={@form_strategy} page_title={@page_title} />
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Strategies List (2 columns) -->
          <div class="lg:col-span-2">
            <h2 class="text-lg font-semibold text-gray-900 mb-4">Your Strategies</h2>

            <%= if Enum.empty?(@strategies) do %>
              <div class="bg-white rounded-lg shadow p-8 text-center">
                <svg class="mx-auto h-12 w-12 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
                </svg>
                <h3 class="mt-2 text-sm font-medium text-gray-900">No strategies yet</h3>
                <p class="mt-1 text-sm text-gray-500">Create a strategy to start monitoring Kalshi markets.</p>
                <div class="mt-4">
                  <.link navigate={~p"/kalshi/new"} class="text-indigo-600 hover:text-indigo-500 font-medium">
                    Create your first strategy →
                  </.link>
                </div>
              </div>
            <% else %>
              <div class="space-y-4">
                <%= for strategy <- @strategies do %>
                  <.strategy_card strategy={strategy} />
                <% end %>
              </div>
            <% end %>
          </div>

          <!-- Alerts Panel (1 column) -->
          <div>
            <h2 class="text-lg font-semibold text-gray-900 mb-4">Recent Alerts</h2>
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <%= if Enum.empty?(@alerts) do %>
                <div class="p-6 text-center text-gray-500 text-sm">
                  No alerts yet. Alerts will appear here when your strategies trigger.
                </div>
              <% else %>
                <ul class="divide-y divide-gray-200 max-h-96 overflow-y-auto">
                  <%= for alert <- @alerts do %>
                    <li class={"p-4 hover:bg-gray-50 #{if !alert.acknowledged, do: "bg-blue-50"}"}>
                      <div class="flex justify-between items-start">
                        <div class="flex-1 min-w-0">
                          <p class={"text-sm font-medium #{severity_class(alert.severity)}"}>
                            <%= alert.message %>
                          </p>
                          <p class="text-xs text-gray-500 mt-1">
                            <%= format_time(alert.inserted_at) %>
                          </p>
                        </div>
                        <%= unless alert.acknowledged do %>
                          <button
                            phx-click="acknowledge_alert"
                            phx-value-id={alert.id}
                            class="ml-2 text-gray-400 hover:text-gray-600"
                            title="Acknowledge"
                          >
                            <svg class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                            </svg>
                          </button>
                        <% end %>
                      </div>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Strategy Card Component
  defp strategy_card(assigns) do
    ~H"""
    <div class="bg-white shadow rounded-lg overflow-hidden hover:shadow-lg transition-shadow">
      <div class="p-5">
        <div class="flex justify-between items-start mb-3">
          <div>
            <h3 class="text-lg font-bold text-gray-900"><%= @strategy.name %></h3>
            <p class="text-sm text-gray-500">
              <%= @strategy.market_ticker || @strategy.event_ticker || "No market selected" %>
            </p>
          </div>
          <span class={status_badge_class(@strategy.status)}>
            <%= String.capitalize(@strategy.status) %>
          </span>
        </div>

        <div class="flex items-center gap-4 text-sm text-gray-600 mb-4">
          <span class="inline-flex items-center">
            <svg class="h-4 w-4 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
            </svg>
            <%= format_strategy_type(@strategy.type) %>
          </span>
          <span class="inline-flex items-center">
            <svg class="h-4 w-4 mr-1" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9" />
            </svg>
            <%= @strategy.stats["total_alerts"] || 0 %> alerts
          </span>
        </div>

        <!-- Config Summary -->
        <div class="bg-gray-50 rounded-lg p-3 text-xs space-y-1 mb-4">
          <%= if @strategy.type == "odds_monitor" do %>
            <.config_line label="Side" value={@strategy.config["target_side"] || "yes"} />
            <%= if @strategy.config["price_below"] do %>
              <.config_line label="Alert below" value={"#{@strategy.config["price_below"]}¢"} />
            <% end %>
            <%= if @strategy.config["price_above"] do %>
              <.config_line label="Alert above" value={"#{@strategy.config["price_above"]}¢"} />
            <% end %>
          <% else %>
            <.config_line label="Action" value={"#{@strategy.config["action"]} #{@strategy.config["side"]}"} />
            <.config_line label="Target" value={"#{@strategy.config["target_price"]}¢"} />
            <.config_line label="Max" value={"#{@strategy.config["max_contracts"]} contracts"} />
          <% end %>
        </div>

        <!-- Actions -->
        <div class="flex gap-2">
          <%= if @strategy.status == "stopped" || @strategy.status == "paused" do %>
            <button
              phx-click="start_strategy"
              phx-value-id={@strategy.id}
              class="flex-1 inline-flex justify-center items-center px-3 py-2 text-sm font-medium rounded-md text-white bg-green-600 hover:bg-green-700"
            >
              <%= if @strategy.status == "paused", do: "Resume", else: "Start" %>
            </button>
          <% end %>

          <%= if @strategy.status == "active" do %>
            <button
              phx-click="stop_strategy"
              phx-value-id={@strategy.id}
              class="flex-1 inline-flex justify-center items-center px-3 py-2 text-sm font-medium rounded-md text-white bg-red-600 hover:bg-red-700"
            >
              Stop
            </button>
          <% end %>

          <.link
            navigate={~p"/kalshi/#{@strategy.id}/orders"}
            class="px-3 py-2 text-sm font-medium rounded-md text-indigo-700 bg-indigo-50 hover:bg-indigo-100"
          >
            Orders
          </.link>

          <.link
            navigate={~p"/kalshi/#{@strategy.id}/edit"}
            class="px-3 py-2 text-sm font-medium rounded-md text-gray-700 bg-gray-100 hover:bg-gray-200"
          >
            Edit
          </.link>

          <button
            phx-click="delete_strategy"
            phx-value-id={@strategy.id}
            data-confirm="Delete this strategy?"
            class="px-3 py-2 text-sm font-medium rounded-md text-red-700 bg-white border border-red-300 hover:bg-red-50"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp config_line(assigns) do
    ~H"""
    <div class="flex justify-between">
      <span class="text-gray-500"><%= @label %>:</span>
      <span class="font-medium text-gray-900"><%= @value %></span>
    </div>
    """
  end

  # Live Dashboard Component
  defp live_dashboard(assigns) do
    ~H"""
    <div class="mb-8 bg-gradient-to-r from-slate-900 to-slate-800 rounded-xl shadow-xl overflow-hidden">
      <div class="p-6">
        <!-- Header Row -->
        <div class="flex items-center justify-between mb-6">
          <div class="flex items-center gap-3">
            <div class="relative">
              <div class={[
                "w-3 h-3 rounded-full",
                cond do
                  @ws_status.connected -> "bg-green-400"
                  @dashboard_stats.active_strategies > 0 -> "bg-yellow-400"
                  true -> "bg-red-400"
                end
              ]}>
              </div>
              <%= if @ws_status.connected or @dashboard_stats.active_strategies > 0 do %>
                <div class={[
                  "absolute inset-0 w-3 h-3 rounded-full animate-ping opacity-75",
                  if(@ws_status.connected, do: "bg-green-400", else: "bg-yellow-400")
                ]}></div>
              <% end %>
            </div>
            <span class="text-white font-semibold text-lg">Live Dashboard</span>
            <span class={[
              "text-xs px-2 py-1 rounded-full font-medium",
              cond do
                @ws_status.connected -> "bg-green-500/20 text-green-300"
                @dashboard_stats.active_strategies > 0 -> "bg-yellow-500/20 text-yellow-300"
                true -> "bg-red-500/20 text-red-300"
              end
            ]}>
              <%= cond do %>
                <% @ws_status.connected -> %>Streaming
                <% @dashboard_stats.active_strategies > 0 -> %>Polling
                <% true -> %>Inactive
              <% end %>
            </span>
          </div>
          <div class="text-slate-400 text-sm">
            <%= if @ws_status.connected do %>
              WS Uptime: <%= format_uptime(@ws_status.uptime_seconds) %>
            <% else %>
              <%= if @dashboard_stats.active_strategies > 0 do %>
                <%= @dashboard_stats.active_strategies %> strategies polling
              <% else %>
                Start a strategy to see live data
              <% end %>
            <% end %>
          </div>
        </div>

        <!-- Stats Cards -->
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
          <div class="bg-slate-800/50 rounded-lg p-4 border border-slate-700">
            <div class="text-slate-400 text-xs uppercase tracking-wide mb-1">Strategies</div>
            <div class="text-2xl font-bold text-white"><%= @dashboard_stats.total_strategies %></div>
            <div class="text-green-400 text-sm"><%= @dashboard_stats.active_strategies %> active</div>
          </div>
          <div class="bg-slate-800/50 rounded-lg p-4 border border-slate-700">
            <div class="text-slate-400 text-xs uppercase tracking-wide mb-1">Total Alerts</div>
            <div class="text-2xl font-bold text-white"><%= @dashboard_stats.total_alerts %></div>
            <div class="text-slate-500 text-sm">all time</div>
          </div>
          <div class="bg-slate-800/50 rounded-lg p-4 border border-slate-700">
            <div class="text-slate-400 text-xs uppercase tracking-wide mb-1">Orders Placed</div>
            <div class="text-2xl font-bold text-white"><%= @dashboard_stats.total_orders %></div>
            <div class="text-slate-500 text-sm">all time</div>
          </div>
          <div class="bg-slate-800/50 rounded-lg p-4 border border-slate-700">
            <div class="text-slate-400 text-xs uppercase tracking-wide mb-1">Markets Watched</div>
            <div class="text-2xl font-bold text-white"><%= map_size(@live_prices) %></div>
            <div class="text-blue-400 text-sm">live feeds</div>
          </div>
        </div>

        <!-- Live Prices and Activity -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <!-- Live Price Tickers -->
          <div class="bg-slate-800/50 rounded-lg border border-slate-700 overflow-hidden">
            <div class="px-4 py-3 border-b border-slate-700 flex items-center gap-2">
              <svg class="w-4 h-4 text-green-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6" />
              </svg>
              <span class="text-white font-medium text-sm">Live Prices</span>
            </div>
            <div class="p-4 max-h-40 overflow-y-auto">
              <%= if map_size(@live_prices) == 0 do %>
                <div class="text-slate-500 text-sm text-center py-2">
                  No live price data yet
                </div>
              <% else %>
                <div class="space-y-2">
                  <%= for {ticker, data} <- @live_prices do %>
                    <div class="flex items-center justify-between text-sm">
                      <span class="text-slate-300 font-mono text-xs truncate max-w-[120px]" title={ticker}>
                        <%= truncate_ticker(ticker) %>
                      </span>
                      <div class="flex items-center gap-3">
                        <span class="text-green-400 font-medium">
                          Y: <%= data.yes_bid || data.yes_ask || "-" %>¢
                        </span>
                        <span class="text-red-400 font-medium">
                          N: <%= data.no_bid || data.no_ask || "-" %>¢
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Activity Feed -->
          <div class="bg-slate-800/50 rounded-lg border border-slate-700 overflow-hidden">
            <div class="px-4 py-3 border-b border-slate-700 flex items-center gap-2">
              <svg class="w-4 h-4 text-blue-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
              </svg>
              <span class="text-white font-medium text-sm">Activity Feed</span>
            </div>
            <div class="p-4 max-h-40 overflow-y-auto">
              <%= if Enum.empty?(@activity_feed) do %>
                <div class="text-slate-500 text-sm text-center py-2">
                  Waiting for activity...
                </div>
              <% else %>
                <div class="space-y-2">
                  <%= for activity <- @activity_feed do %>
                    <div class="flex items-start gap-2 text-sm">
                      <span class={activity_icon_class(activity.type)}></span>
                      <div class="flex-1 min-w-0">
                        <p class={[
                          "truncate",
                          activity_text_class(activity.severity)
                        ]}>
                          <%= activity.message %>
                        </p>
                        <p class="text-slate-500 text-xs">
                          <%= format_activity_time(activity.timestamp) %>
                        </p>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp truncate_ticker(ticker) when byte_size(ticker) > 20, do: String.slice(ticker, 0, 17) <> "..."
  defp truncate_ticker(ticker), do: ticker

  defp activity_icon_class(:alert), do: "w-2 h-2 mt-1.5 rounded-full bg-yellow-400"
  defp activity_icon_class(:fill), do: "w-2 h-2 mt-1.5 rounded-full bg-green-400"
  defp activity_icon_class(:order), do: "w-2 h-2 mt-1.5 rounded-full bg-blue-400"
  defp activity_icon_class(_), do: "w-2 h-2 mt-1.5 rounded-full bg-slate-400"

  defp activity_text_class("critical"), do: "text-red-300"
  defp activity_text_class("warning"), do: "text-yellow-300"
  defp activity_text_class(_), do: "text-slate-300"

  defp format_activity_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)
    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> Calendar.strftime(datetime, "%H:%M")
    end
  end

  # Strategy Form Component
  defp strategy_form(assigns) do
    ~H"""
    <div class="fixed inset-0 flex items-center justify-center p-4 z-50" style="background-color: rgba(0, 0, 0, 0.3);">
      <div class="bg-white rounded-lg shadow-xl max-w-2xl w-full p-6 max-h-[90vh] overflow-y-auto">
        <div class="flex justify-between items-start mb-6">
          <h2 class="text-2xl font-bold text-gray-900"><%= @page_title %></h2>
          <.link navigate={~p"/kalshi"} class="text-gray-400 hover:text-gray-500">
            <svg class="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </.link>
        </div>

        <.form for={%{}} phx-submit="save_strategy" class="space-y-6">
          <!-- Basic Info -->
          <div class="space-y-4">
            <h3 class="text-lg font-semibold text-gray-900">Basic Information</h3>

            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Strategy Name</label>
              <input
                type="text"
                name="strategy[name]"
                value={@form_strategy.name}
                required
                class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                placeholder="My BTC Prediction Strategy"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Market Ticker</label>
              <input
                type="text"
                name="strategy[market_ticker]"
                value={@form_strategy.market_ticker}
                class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                placeholder="KXBTC-24DEC31-T100000"
              />
              <p class="mt-1 text-xs text-gray-500">Enter a specific Kalshi market ticker</p>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Strategy Type</label>
              <select
                name="strategy[type]"
                class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
              >
                <option value="odds_monitor" selected={@form_strategy.type == "odds_monitor"}>
                  Odds Monitor (Alerts Only)
                </option>
                <option value="auto_bid" selected={@form_strategy.type == "auto_bid"}>
                  Auto Bid (Automatic Trading)
                </option>
              </select>
            </div>
          </div>

          <!-- Odds Monitor Config -->
          <div class="space-y-4 pt-4 border-t">
            <h3 class="text-lg font-semibold text-gray-900">Monitoring Configuration</h3>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Target Side</label>
                <select
                  name="strategy[config][target_side]"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                >
                  <option value="yes" selected={get_in(@form_strategy.config, ["target_side"]) == "yes"}>YES</option>
                  <option value="no" selected={get_in(@form_strategy.config, ["target_side"]) == "no"}>NO</option>
                </select>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Price Change Alert (%)</label>
                <input
                  type="number"
                  name="strategy[config][alert_on_change_pct]"
                  value={get_in(@form_strategy.config, ["alert_on_change_pct"]) || 10}
                  step="1"
                  min="1"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                />
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Alert Below (¢)</label>
                <input
                  type="number"
                  name="strategy[config][price_below]"
                  value={get_in(@form_strategy.config, ["price_below"])}
                  min="1"
                  max="99"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                  placeholder="30"
                />
                <p class="mt-1 text-xs text-gray-500">Alert when price drops below this</p>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Alert Above (¢)</label>
                <input
                  type="number"
                  name="strategy[config][price_above]"
                  value={get_in(@form_strategy.config, ["price_above"])}
                  min="1"
                  max="99"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                  placeholder="70"
                />
                <p class="mt-1 text-xs text-gray-500">Alert when price rises above this</p>
              </div>
            </div>
          </div>

          <!-- Auto-Bid Config (shown for auto_bid type) -->
          <div class="space-y-4 pt-4 border-t">
            <h3 class="text-lg font-semibold text-gray-900">Auto-Bid Settings</h3>
            <p class="text-sm text-gray-500">Configure automatic order placement (only active for Auto Bid strategy type)</p>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Action</label>
                <select
                  name="strategy[config][action]"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                >
                  <option value="buy" selected={get_in(@form_strategy.config, ["action"]) == "buy"}>Buy</option>
                  <option value="sell" selected={get_in(@form_strategy.config, ["action"]) == "sell"}>Sell</option>
                </select>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Side</label>
                <select
                  name="strategy[config][side]"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                >
                  <option value="yes" selected={get_in(@form_strategy.config, ["side"]) == "yes"}>YES</option>
                  <option value="no" selected={get_in(@form_strategy.config, ["side"]) == "no"}>NO</option>
                </select>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Target Price (¢)</label>
                <input
                  type="number"
                  name="strategy[config][target_price]"
                  value={get_in(@form_strategy.config, ["target_price"]) || 25}
                  min="1"
                  max="99"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                />
                <p class="mt-1 text-xs text-gray-500">Price to place your order at</p>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Max Contracts</label>
                <input
                  type="number"
                  name="strategy[config][max_contracts]"
                  value={get_in(@form_strategy.config, ["max_contracts"]) || 10}
                  min="1"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                />
              </div>
            </div>

            <div class="flex items-center">
              <input
                type="checkbox"
                name="strategy[config][enabled]"
                value="true"
                checked={get_in(@form_strategy.config, ["enabled"])}
                class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded"
              />
              <label class="ml-2 text-sm text-gray-700">Enable automatic trading</label>
            </div>
          </div>

          <!-- Risk Parameters -->
          <div class="space-y-4 pt-4 border-t">
            <h3 class="text-lg font-semibold text-gray-900">Risk Management</h3>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Max Position (contracts)</label>
                <input
                  type="number"
                  name="strategy[risk_params][max_position_size]"
                  value={get_in(@form_strategy.risk_params, ["max_position_size"]) || 100}
                  min="1"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                />
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Max Daily Loss ($)</label>
                <input
                  type="number"
                  name="strategy[risk_params][max_daily_loss_cents]"
                  value={div(get_in(@form_strategy.risk_params, ["max_daily_loss_cents"]) || 5000, 100)}
                  min="1"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                />
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-2">Cooldown (seconds)</label>
                <input
                  type="number"
                  name="strategy[risk_params][cooldown_seconds]"
                  value={get_in(@form_strategy.risk_params, ["cooldown_seconds"]) || 60}
                  min="0"
                  class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                />
              </div>
            </div>
          </div>

          <!-- Alert Config -->
          <div class="space-y-4 pt-4 border-t">
            <h3 class="text-lg font-semibold text-gray-900">Alert Settings</h3>

            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Alert Cooldown (seconds)</label>
              <input
                type="number"
                name="strategy[alert_config][alert_cooldown_seconds]"
                value={get_in(@form_strategy.alert_config, ["alert_cooldown_seconds"]) || 300}
                min="0"
                class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
              />
              <p class="mt-1 text-xs text-gray-500">Minimum time between repeat alerts</p>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Webhook URL (optional)</label>
              <input
                type="url"
                name="strategy[alert_config][webhook_url]"
                value={get_in(@form_strategy.alert_config, ["webhook_url"])}
                class="w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                placeholder="https://your-webhook.com/alerts"
              />
            </div>
          </div>

          <!-- Actions -->
          <div class="flex gap-3 pt-4">
            <button
              type="submit"
              class="flex-1 inline-flex justify-center items-center px-4 py-2 border border-transparent text-base font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700"
            >
              Save Strategy
            </button>
            <.link
              navigate={~p"/kalshi"}
              class="px-4 py-2 border border-gray-300 text-base font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50"
            >
              Cancel
            </.link>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # Helper functions
  defp list_strategies, do: Strategies.list_strategies()
  defp list_recent_alerts, do: Strategies.list_recent_alerts(limit: 20)
  defp api_configured?, do: SofiTrader.Kalshi.Client.configured?()

  defp get_ws_status do
    if Process.whereis(WebSocketManager) do
      try do
        WebSocketManager.status()
      catch
        :exit, _ -> %{connected: false, uptime_seconds: 0, subscriptions: %{}, reconnect_count: 0}
      end
    else
      %{connected: false, uptime_seconds: 0, subscriptions: %{}, reconnect_count: 0}
    end
  end

  defp get_dashboard_stats do
    strategies = list_strategies()
    active_count = Enum.count(strategies, &(&1.status == "active"))
    total_alerts = Enum.reduce(strategies, 0, fn s, acc ->
      acc + (s.stats["total_alerts"] || 0)
    end)
    total_orders = Enum.reduce(strategies, 0, fn s, acc ->
      acc + (s.stats["total_orders"] || 0)
    end)

    %{
      total_strategies: length(strategies),
      active_strategies: active_count,
      total_alerts: total_alerts,
      total_orders: total_orders
    }
  end

  defp subscribe_to_strategy_tickers do
    # Subscribe to price updates for all strategy market tickers
    Strategies.list_strategies()
    |> Enum.each(fn strategy ->
      if strategy.market_ticker do
        Phoenix.PubSub.subscribe(SofiTrader.PubSub, "kalshi:ticker:#{strategy.market_ticker}")
      end
    end)
  end

  defp status_badge_class("active"), do: "px-2 py-1 text-xs font-semibold rounded-full bg-green-100 text-green-800"
  defp status_badge_class("paused"), do: "px-2 py-1 text-xs font-semibold rounded-full bg-yellow-100 text-yellow-800"
  defp status_badge_class(_), do: "px-2 py-1 text-xs font-semibold rounded-full bg-gray-100 text-gray-800"

  defp severity_class("critical"), do: "text-red-600"
  defp severity_class("warning"), do: "text-yellow-600"
  defp severity_class(_), do: "text-gray-900"

  defp format_strategy_type("odds_monitor"), do: "Odds Monitor"
  defp format_strategy_type("auto_bid"), do: "Auto Bid"
  defp format_strategy_type(type), do: type

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map(fn {key, errors} -> "#{key}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
