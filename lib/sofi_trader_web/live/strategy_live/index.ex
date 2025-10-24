defmodule SofiTraderWeb.StrategyLive.Index do
  use SofiTraderWeb, :live_view

  alias SofiTrader.Strategies
  alias SofiTrader.Strategies.{Strategy, Supervisor}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to strategy updates
      Phoenix.PubSub.subscribe(SofiTrader.PubSub, "strategies")
    end

    socket =
      socket
      |> assign(:strategies, list_strategies())
      |> assign(:show_form, false)
      |> assign(:form_strategy, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Trading Strategies")
    |> assign(:show_form, false)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Strategy")
    |> assign(:show_form, true)
    |> assign(:form_strategy, %Strategy{
      config: Strategy.default_config("rsi_mean_reversion"),
      risk_params: Strategy.default_risk_params(),
      stats: Strategy.initial_stats()
    })
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    strategy = Strategies.get_strategy!(id)

    socket
    |> assign(:page_title, "Edit Strategy")
    |> assign(:show_form, true)
    |> assign(:form_strategy, strategy)
  end

  @impl true
  def handle_event("start_strategy", %{"id" => id}, socket) do
    strategy = Strategies.get_strategy!(String.to_integer(id))

    case Strategies.start_strategy(strategy) do
      {:ok, updated_strategy} ->
        # Start the runner
        Supervisor.start_strategy(updated_strategy.id, paper_trading: true)

        socket =
          socket
          |> put_flash(:info, "Strategy started successfully")
          |> assign(:strategies, list_strategies())

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to start strategy")}
    end
  end

  @impl true
  def handle_event("stop_strategy", %{"id" => id}, socket) do
    strategy = Strategies.get_strategy!(String.to_integer(id))

    case Strategies.stop_strategy(strategy) do
      {:ok, _updated_strategy} ->
        # Stop the runner
        Supervisor.stop_strategy(strategy.id)

        socket =
          socket
          |> put_flash(:info, "Strategy stopped successfully")
          |> assign(:strategies, list_strategies())

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to stop strategy")}
    end
  end

  @impl true
  def handle_event("pause_strategy", %{"id" => id}, socket) do
    strategy = Strategies.get_strategy!(String.to_integer(id))

    case Strategies.pause_strategy(strategy) do
      {:ok, _updated_strategy} ->
        # Stop the runner
        Supervisor.stop_strategy(strategy.id)

        socket =
          socket
          |> put_flash(:info, "Strategy paused successfully")
          |> assign(:strategies, list_strategies())

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to pause strategy")}
    end
  end

  @impl true
  def handle_event("delete_strategy", %{"id" => id}, socket) do
    strategy = Strategies.get_strategy!(String.to_integer(id))

    # Stop if running
    if strategy.status == "active" do
      Supervisor.stop_strategy(strategy.id)
    end

    case Strategies.delete_strategy(strategy) do
      {:ok, _strategy} ->
        socket =
          socket
          |> put_flash(:info, "Strategy deleted successfully")
          |> assign(:strategies, list_strategies())

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete strategy")}
    end
  end

  @impl true
  def handle_event("save_strategy", %{"strategy" => strategy_params}, socket) do
    save_strategy(socket, socket.assigns.live_action, strategy_params)
  end

  defp save_strategy(socket, :new, strategy_params) do
    case Strategies.create_strategy(strategy_params) do
      {:ok, _strategy} ->
        socket =
          socket
          |> put_flash(:info, "Strategy created successfully")
          |> assign(:strategies, list_strategies())
          |> push_navigate(to: ~p"/strategies")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create strategy: #{format_errors(changeset)}")}
    end
  end

  defp save_strategy(socket, :edit, strategy_params) do
    strategy = socket.assigns.form_strategy

    case Strategies.update_strategy(strategy, strategy_params) do
      {:ok, _strategy} ->
        socket =
          socket
          |> put_flash(:info, "Strategy updated successfully")
          |> assign(:strategies, list_strategies())
          |> push_navigate(to: ~p"/strategies")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update strategy: #{format_errors(changeset)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <!-- Header -->
        <div class="mb-8 flex justify-between items-center">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">Trading Strategies</h1>
            <p class="mt-2 text-sm text-gray-600">
              Manage and monitor your automated trading strategies
            </p>
          </div>
          <.link
            navigate={~p"/strategies/new"}
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
          >
            <svg class="h-5 w-5 mr-2" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
            </svg>
            New Strategy
          </.link>
        </div>

        <!-- Strategy Form Modal -->
        <%= if @show_form do %>
          <div class="fixed inset-0 flex items-center justify-center p-4 z-50" style="background-color: rgba(0, 0, 0, 0.3); backdrop-filter: blur(2px);">
            <div class="bg-white rounded-lg shadow-xl max-w-3xl w-full p-6 max-h-[90vh] overflow-y-auto">
              <div class="flex justify-between items-start mb-6">
                <h2 class="text-2xl font-bold text-gray-900"><%= @page_title %></h2>
                <.link navigate={~p"/strategies"} class="text-gray-400 hover:text-gray-500">
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
                      class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      placeholder="My AAPL RSI Strategy"
                    />
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-700 mb-2">Symbol</label>
                    <input
                      type="text"
                      name="strategy[symbol]"
                      value={@form_strategy.symbol}
                      required
                      class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      placeholder="AAPL"
                    />
                  </div>

                  <div>
                    <label class="block text-sm font-medium text-gray-700 mb-2">Strategy Type</label>
                    <select
                      name="strategy[type]"
                      class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                    >
                      <option value="rsi_mean_reversion" selected={@form_strategy.type == "rsi_mean_reversion"}>
                        RSI Mean Reversion
                      </option>
                    </select>
                  </div>
                </div>

                <!-- Strategy Configuration -->
                <div class="space-y-4 pt-4 border-t">
                  <h3 class="text-lg font-semibold text-gray-900">Strategy Configuration</h3>

                  <div class="grid grid-cols-2 gap-4">
                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">RSI Period</label>
                      <input
                        type="number"
                        name="strategy[config][rsi_period]"
                        value={get_in(@form_strategy.config, ["rsi_period"]) || 14}
                        min="1"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                    </div>

                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Timeframe</label>
                      <select
                        name="strategy[config][timeframe]"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      >
                        <option value="1min">1 Minute</option>
                        <option value="5min" selected={get_in(@form_strategy.config, ["timeframe"]) == "5min"}>5 Minutes</option>
                        <option value="15min">15 Minutes</option>
                        <option value="30min">30 Minutes</option>
                        <option value="1hour">1 Hour</option>
                        <option value="daily">Daily</option>
                      </select>
                    </div>

                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Oversold Threshold</label>
                      <input
                        type="number"
                        name="strategy[config][oversold_threshold]"
                        value={get_in(@form_strategy.config, ["oversold_threshold"]) || 30}
                        min="1"
                        max="100"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                    </div>

                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Overbought Threshold</label>
                      <input
                        type="number"
                        name="strategy[config][overbought_threshold]"
                        value={get_in(@form_strategy.config, ["overbought_threshold"]) || 70}
                        min="1"
                        max="100"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                    </div>
                  </div>
                </div>

                <!-- Risk Parameters -->
                <div class="space-y-4 pt-4 border-t">
                  <h3 class="text-lg font-semibold text-gray-900">Risk Management</h3>

                  <div class="grid grid-cols-2 gap-4">
                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Position Size (%)</label>
                      <input
                        type="number"
                        name="strategy[risk_params][position_size_pct]"
                        value={get_in(@form_strategy.risk_params, ["position_size_pct"]) || 10.0}
                        step="0.1"
                        min="0.1"
                        max="50"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                      <p class="mt-1 text-xs text-gray-500">Percentage of buying power per trade</p>
                    </div>

                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Stop Loss (%)</label>
                      <input
                        type="number"
                        name="strategy[risk_params][stop_loss_pct]"
                        value={get_in(@form_strategy.risk_params, ["stop_loss_pct"]) || 2.0}
                        step="0.1"
                        min="0.1"
                        max="20"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                      <p class="mt-1 text-xs text-gray-500">Auto-exit if position drops X%</p>
                    </div>

                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Take Profit (%)</label>
                      <input
                        type="number"
                        name="strategy[risk_params][take_profit_pct]"
                        value={get_in(@form_strategy.risk_params, ["take_profit_pct"]) || 5.0}
                        step="0.1"
                        min="0.1"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                      <p class="mt-1 text-xs text-gray-500">Auto-exit if position gains X%</p>
                    </div>

                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Max Positions</label>
                      <input
                        type="number"
                        name="strategy[risk_params][max_positions]"
                        value={get_in(@form_strategy.risk_params, ["max_positions"]) || 3}
                        min="1"
                        max="10"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                      <p class="mt-1 text-xs text-gray-500">Maximum concurrent positions</p>
                    </div>

                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Max Daily Loss (%)</label>
                      <input
                        type="number"
                        name="strategy[risk_params][max_daily_loss_pct]"
                        value={get_in(@form_strategy.risk_params, ["max_daily_loss_pct"]) || 3.0}
                        step="0.1"
                        min="0.1"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                      <p class="mt-1 text-xs text-gray-500">Circuit breaker to stop all trading</p>
                    </div>

                    <div>
                      <label class="block text-sm font-medium text-gray-700 mb-2">Cooldown (minutes)</label>
                      <input
                        type="number"
                        name="strategy[risk_params][cooldown_minutes]"
                        value={get_in(@form_strategy.risk_params, ["cooldown_minutes"]) || 15}
                        min="0"
                        class="w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500"
                      />
                      <p class="mt-1 text-xs text-gray-500">Minimum time between trades</p>
                    </div>
                  </div>
                </div>

                <!-- Actions -->
                <div class="flex gap-3 pt-4">
                  <button
                    type="submit"
                    class="flex-1 inline-flex justify-center items-center px-4 py-2 border border-transparent text-base font-medium rounded-md text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
                  >
                    Save Strategy
                  </button>
                  <.link
                    navigate={~p"/strategies"}
                    class="px-4 py-2 border border-gray-300 text-base font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500"
                  >
                    Cancel
                  </.link>
                </div>
              </.form>
            </div>
          </div>
        <% end %>

        <!-- Strategies List -->
        <%= if Enum.empty?(@strategies) do %>
          <div class="text-center py-12">
            <svg class="mx-auto h-12 w-12 text-gray-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
            </svg>
            <h3 class="mt-2 text-sm font-medium text-gray-900">No strategies</h3>
            <p class="mt-1 text-sm text-gray-500">Get started by creating a new strategy.</p>
            <div class="mt-6">
              <.link
                navigate={~p"/strategies/new"}
                class="inline-flex items-center px-4 py-2 border border-transparent shadow-sm text-sm font-medium rounded-md text-white bg-blue-600 hover:bg-blue-700"
              >
                Create Strategy
              </.link>
            </div>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            <%= for strategy <- @strategies do %>
              <div class="bg-white shadow rounded-lg overflow-hidden hover:shadow-lg transition-shadow">
                <div class="p-6">
                  <!-- Header -->
                  <div class="flex justify-between items-start mb-4">
                    <div class="flex-1">
                      <h3 class="text-lg font-bold text-gray-900"><%= strategy.name %></h3>
                      <p class="text-sm text-gray-500 mt-1"><%= strategy.symbol %></p>
                    </div>
                    <span class={status_badge_class(strategy.status)}>
                      <%= String.capitalize(strategy.status) %>
                    </span>
                  </div>

                  <!-- Stats -->
                  <div class="space-y-2 mb-4">
                    <div class="flex justify-between text-sm">
                      <span class="text-gray-500">Win Rate:</span>
                      <span class="font-semibold"><%= format_percent(get_in(strategy.stats, ["win_rate"]) || 0) %></span>
                    </div>
                    <div class="flex justify-between text-sm">
                      <span class="text-gray-500">Total P&L:</span>
                      <span class={pnl_class(get_in(strategy.stats, ["total_pnl"]) || 0)}>
                        $<%= format_number(get_in(strategy.stats, ["total_pnl"]) || 0) %>
                      </span>
                    </div>
                    <div class="flex justify-between text-sm">
                      <span class="text-gray-500">Trades:</span>
                      <span class="font-semibold"><%= get_in(strategy.stats, ["total_trades"]) || 0 %></span>
                    </div>
                  </div>

                  <!-- Config Summary -->
                  <div class="pt-4 border-t text-xs text-gray-600 space-y-1">
                    <div>Type: <%= format_strategy_type(strategy.type) %></div>
                    <div>Timeframe: <%= get_in(strategy.config, ["timeframe"]) || "5min" %></div>
                    <div>Position Size: <%= get_in(strategy.risk_params, ["position_size_pct"]) || 10 %>%</div>
                  </div>

                  <!-- Actions -->
                  <div class="mt-4 pt-4 border-t flex gap-2">
                    <%= if strategy.status == "stopped" do %>
                      <button
                        phx-click="start_strategy"
                        phx-value-id={strategy.id}
                        class="flex-1 inline-flex justify-center items-center px-3 py-2 text-sm font-medium rounded-md text-white bg-green-600 hover:bg-green-700"
                      >
                        Start
                      </button>
                    <% end %>

                    <%= if strategy.status == "active" do %>
                      <button
                        phx-click="pause_strategy"
                        phx-value-id={strategy.id}
                        class="flex-1 inline-flex justify-center items-center px-3 py-2 text-sm font-medium rounded-md text-white bg-yellow-600 hover:bg-yellow-700"
                      >
                        Pause
                      </button>
                      <button
                        phx-click="stop_strategy"
                        phx-value-id={strategy.id}
                        class="flex-1 inline-flex justify-center items-center px-3 py-2 text-sm font-medium rounded-md text-white bg-red-600 hover:bg-red-700"
                      >
                        Stop
                      </button>
                    <% end %>

                    <%= if strategy.status == "paused" do %>
                      <button
                        phx-click="start_strategy"
                        phx-value-id={strategy.id}
                        class="flex-1 inline-flex justify-center items-center px-3 py-2 text-sm font-medium rounded-md text-white bg-green-600 hover:bg-green-700"
                      >
                        Resume
                      </button>
                      <button
                        phx-click="stop_strategy"
                        phx-value-id={strategy.id}
                        class="flex-1 inline-flex justify-center items-center px-3 py-2 text-sm font-medium rounded-md text-white bg-red-600 hover:bg-red-700"
                      >
                        Stop
                      </button>
                    <% end %>

                    <.link
                      navigate={~p"/strategies/#{strategy.id}"}
                      class="px-3 py-2 text-sm font-medium rounded-md text-gray-700 bg-gray-100 hover:bg-gray-200"
                    >
                      Monitor
                    </.link>
                  </div>

                  <!-- Secondary Actions -->
                  <div class="mt-2 flex gap-2">
                    <.link
                      navigate={~p"/strategies/#{strategy.id}/edit"}
                      class="flex-1 text-center px-3 py-1 text-xs font-medium rounded-md text-gray-700 bg-white border border-gray-300 hover:bg-gray-50"
                    >
                      Edit
                    </.link>
                    <button
                      phx-click="delete_strategy"
                      phx-value-id={strategy.id}
                      data-confirm="Are you sure you want to delete this strategy?"
                      class="flex-1 px-3 py-1 text-xs font-medium rounded-md text-red-700 bg-white border border-red-300 hover:bg-red-50"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp list_strategies do
    Strategies.list_strategies()
  end

  defp status_badge_class("active"), do: "px-2 py-1 text-xs font-semibold rounded-full bg-green-100 text-green-800"
  defp status_badge_class("paused"), do: "px-2 py-1 text-xs font-semibold rounded-full bg-yellow-100 text-yellow-800"
  defp status_badge_class("stopped"), do: "px-2 py-1 text-xs font-semibold rounded-full bg-gray-100 text-gray-800"
  defp status_badge_class(_), do: "px-2 py-1 text-xs font-semibold rounded-full bg-gray-100 text-gray-800"

  defp pnl_class(pnl) when pnl > 0, do: "font-semibold text-green-600"
  defp pnl_class(pnl) when pnl < 0, do: "font-semibold text-red-600"
  defp pnl_class(_), do: "font-semibold text-gray-600"

  defp format_percent(num), do: "#{:erlang.float_to_binary(num * 1.0, decimals: 1)}%"
  defp format_number(num), do: :erlang.float_to_binary(num * 1.0, decimals: 2)

  defp format_strategy_type("rsi_mean_reversion"), do: "RSI Mean Reversion"
  defp format_strategy_type("ma_crossover"), do: "MA Crossover"
  defp format_strategy_type(type), do: type

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map(fn {key, errors} -> "#{key}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
