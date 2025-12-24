defmodule SofiTrader.Kalshi.StrategyRunner do
  @moduledoc """
  GenServer that runs a Kalshi prediction market strategy.

  Each active strategy has its own Runner process that:
  - Subscribes to real-time market data via WebSocket
  - Monitors price/volume against configured thresholds
  - Generates alerts when conditions are met
  - Places orders automatically for auto-bid strategies
  - Tracks positions and updates P&L

  ## Strategy Types

  ### Odds Monitor
  Watches markets for price/volume conditions and sends alerts:
  - Price crosses threshold (above/below)
  - Volume spikes
  - Significant price changes

  ### Auto Bid
  Automatically places orders when conditions are met:
  - Trigger price reached
  - Volume conditions satisfied
  - Risk limits not exceeded

  ## Architecture

  The Runner subscribes to PubSub topics broadcast by the WebSocketManager:
  - `kalshi:ticker:{ticker}` - Price/volume updates
  - `kalshi:orderbook:{ticker}` - Orderbook changes
  - `kalshi:fill:{ticker}` - Order fills
  """

  use GenServer
  require Logger

  alias SofiTrader.Kalshi.{Strategies, Alert, Orders, Markets, WebSocketManager}

  @price_history_size 100
  @poll_interval_ms 10_000  # Poll every 10 seconds for market updates

  defstruct [
    :strategy_id,
    :strategy,
    :market_ticker,
    :last_ticker_data,
    :price_history,        # List of {timestamp, yes_price, no_price}
    :pending_orders,       # Map of order_id => order
    :last_alert_at,
    :last_trade_at,
    :paper_trading,
    :poll_timer
  ]

  ## Client API

  @doc """
  Starts a strategy runner.
  """
  def start_link(opts) do
    strategy_id = Keyword.fetch!(opts, :strategy_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(strategy_id))
  end

  @doc """
  Stops a strategy runner.
  """
  def stop(strategy_id) do
    GenServer.stop(via_tuple(strategy_id))
  end

  @doc """
  Gets the current state of a running strategy.
  """
  def get_state(strategy_id) do
    GenServer.call(via_tuple(strategy_id), :get_state)
  end

  @doc """
  Force evaluation of conditions (useful for testing).
  """
  def force_evaluate(strategy_id) do
    GenServer.call(via_tuple(strategy_id), :force_evaluate)
  end

  @doc """
  Check if a runner is alive for a strategy.
  """
  def running?(strategy_id) do
    case Registry.lookup(SofiTrader.KalshiStrategyRegistry, strategy_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  defp via_tuple(strategy_id) do
    {:via, Registry, {SofiTrader.KalshiStrategyRegistry, strategy_id}}
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    strategy_id = Keyword.fetch!(opts, :strategy_id)
    paper_trading = Keyword.get(opts, :paper_trading, true)

    Logger.info("[Kalshi Strategy #{strategy_id}] Starting")

    case Strategies.get_strategy(strategy_id) do
      nil ->
        Logger.error("[Kalshi Strategy #{strategy_id}] Strategy not found")
        {:stop, :strategy_not_found}

      strategy ->
        # Get the market ticker
        market_ticker = strategy.market_ticker

        if market_ticker do
          # Subscribe to market data
          Phoenix.PubSub.subscribe(SofiTrader.PubSub, "kalshi:ticker:#{market_ticker}")
          Phoenix.PubSub.subscribe(SofiTrader.PubSub, "kalshi:fill:#{market_ticker}")

          # Register with WebSocket manager for real-time updates
          if WebSocketManager.configured?() do
            WebSocketManager.subscribe_all(market_ticker)
          end

          # Start periodic polling for market data
          timer_ref = Process.send_after(self(), :poll_market, 1_000)

          state = %__MODULE__{
            strategy_id: strategy_id,
            strategy: strategy,
            market_ticker: market_ticker,
            last_ticker_data: nil,
            price_history: [],
            pending_orders: %{},
            last_alert_at: strategy.last_alert_at,
            last_trade_at: strategy.last_trade_at,
            paper_trading: paper_trading,
            poll_timer: timer_ref
          }

          Logger.info("[Kalshi Strategy #{strategy_id}] Subscribed to #{market_ticker}")
          {:ok, state}
        else
          Logger.warning("[Kalshi Strategy #{strategy_id}] No market ticker configured")
          {:ok, %__MODULE__{strategy_id: strategy_id, strategy: strategy}}
        end
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:force_evaluate, _from, state) do
    case evaluate_conditions(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Handle ticker updates from WebSocket
  @impl true
  def handle_info({:ticker_update, ticker_data}, state) do
    # Update price history
    new_history = update_price_history(state.price_history, ticker_data)

    state = %{state |
      last_ticker_data: ticker_data,
      price_history: new_history
    }

    # Evaluate strategy conditions
    case evaluate_conditions(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  # Handle fill notifications
  @impl true
  def handle_info({:fill_update, fill_data}, state) do
    Logger.info("[Kalshi Strategy #{state.strategy_id}] Fill received: #{inspect(fill_data)}")

    # Update order status and position
    order_id = fill_data["order_id"]

    case Map.get(state.pending_orders, order_id) do
      nil ->
        {:noreply, state}

      order ->
        # Update order in database
        Strategies.update_order(order, %{
          filled_count: fill_data["count"],
          avg_fill_price_cents: fill_data["price"],
          status: "executed",
          filled_at: DateTime.utc_now()
        })

        # Create or update position
        handle_fill(state, order, fill_data)

        # Remove from pending
        new_pending = Map.delete(state.pending_orders, order_id)
        {:noreply, %{state | pending_orders: new_pending, last_trade_at: DateTime.utc_now()}}
    end
  end

  # Handle periodic market polling
  @impl true
  def handle_info(:poll_market, state) do
    state = poll_market_data(state)

    # Schedule next poll
    timer_ref = Process.send_after(self(), :poll_market, @poll_interval_ms)
    {:noreply, %{state | poll_timer: timer_ref}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[Kalshi Strategy #{state.strategy_id}] Unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[Kalshi Strategy #{state.strategy_id}] Terminating: #{inspect(reason)}")

    # Cancel poll timer
    if state.poll_timer do
      Process.cancel_timer(state.poll_timer)
    end

    # Unsubscribe from WebSocket
    if state.market_ticker && WebSocketManager.configured?() do
      WebSocketManager.unsubscribe(state.market_ticker)
    end

    :ok
  end

  ## Private Functions

  defp poll_market_data(state) do
    case Markets.get_market(state.market_ticker) do
      {:ok, %{"market" => market_data}} ->
        # Convert API response to ticker_data format
        ticker_data = %{
          ticker: state.market_ticker,
          yes_bid: market_data["yes_bid"],
          yes_ask: market_data["yes_ask"],
          no_bid: market_data["no_bid"],
          no_ask: market_data["no_ask"],
          last_price: market_data["last_price"],
          volume: market_data["volume"] || 0,
          open_interest: market_data["open_interest"] || 0,
          timestamp: DateTime.utc_now()
        }

        Logger.debug("[Kalshi Strategy #{state.strategy_id}] Polled: YES #{ticker_data.yes_bid}/#{ticker_data.yes_ask}¢")

        # Broadcast to PubSub so LiveView can display live prices
        Phoenix.PubSub.broadcast(
          SofiTrader.PubSub,
          "kalshi:ticker:#{state.market_ticker}",
          {:ticker_update, ticker_data}
        )

        # Update price history
        new_history = update_price_history(state.price_history, ticker_data)

        state = %{state |
          last_ticker_data: ticker_data,
          price_history: new_history
        }

        # Evaluate strategy conditions
        case evaluate_conditions(state) do
          {:ok, new_state} -> new_state
          {:error, _reason} -> state
        end

      {:error, reason} ->
        Logger.warning("[Kalshi Strategy #{state.strategy_id}] Poll failed: #{inspect(reason)}")
        state
    end
  end

  defp update_price_history(history, ticker_data) do
    entry = {
      DateTime.utc_now(),
      ticker_data.yes_bid || ticker_data.yes_ask,
      ticker_data.no_bid || ticker_data.no_ask
    }

    [entry | history]
    |> Enum.take(@price_history_size)
  end

  defp evaluate_conditions(state) do
    strategy = state.strategy
    config = strategy.config

    case strategy.type do
      "odds_monitor" -> evaluate_odds_monitor(state, config)
      "auto_bid" -> evaluate_auto_bid(state, config)
      _ -> {:ok, state}
    end
  end

  ## Odds Monitor Evaluation

  defp evaluate_odds_monitor(state, config) do
    ticker_data = state.last_ticker_data

    unless ticker_data do
      {:ok, state}
    else
      # Check price thresholds
      state = check_price_threshold(state, ticker_data, config)

      # Check volume threshold
      state = check_volume_threshold(state, ticker_data, config)

      # Check price change percentage
      state = check_price_change(state, config)

      {:ok, state}
    end
  end

  defp check_price_threshold(state, ticker_data, config) do
    target_side = config["target_side"] || "yes"
    current_price = get_price_for_side(ticker_data, target_side)

    state
    |> check_price_below(current_price, config["price_below"], target_side)
    |> check_price_above(current_price, config["price_above"], target_side)
  end

  defp check_price_below(state, _price, nil, _side), do: state
  defp check_price_below(state, price, threshold, side) when price < threshold do
    maybe_send_alert(state, :price_threshold, %{
      side: side,
      price: price,
      threshold: threshold,
      direction: "below"
    })
  end
  defp check_price_below(state, _, _, _), do: state

  defp check_price_above(state, _price, nil, _side), do: state
  defp check_price_above(state, price, threshold, side) when price > threshold do
    maybe_send_alert(state, :price_threshold, %{
      side: side,
      price: price,
      threshold: threshold,
      direction: "above"
    })
  end
  defp check_price_above(state, _, _, _), do: state

  defp check_volume_threshold(state, ticker_data, config) do
    case config["volume_threshold"] do
      nil -> state
      threshold when ticker_data.volume >= threshold ->
        maybe_send_alert(state, :volume_spike, %{
          volume: ticker_data.volume,
          threshold: threshold
        })
      _ -> state
    end
  end

  defp check_price_change(state, config) do
    case {config["alert_on_change_pct"], length(state.price_history)} do
      {nil, _} -> state
      {_, len} when len < 2 -> state
      {threshold, _} ->
        [{_, current_yes, _} | _] = state.price_history
        {_, old_yes, _} = Enum.at(state.price_history, -1)

        if old_yes && old_yes > 0 do
          change_pct = abs((current_yes - old_yes) / old_yes * 100)
          if change_pct >= threshold do
            maybe_send_alert(state, :price_change, %{
              change_pct: Float.round(change_pct, 2),
              from_price: old_yes,
              to_price: current_yes
            })
          else
            state
          end
        else
          state
        end
    end
  end

  ## Auto Bid Evaluation

  defp evaluate_auto_bid(state, config) do
    unless config["enabled"] do
      {:ok, state}
    else
      ticker_data = state.last_ticker_data

      unless ticker_data do
        {:ok, state}
      else
        # Check if trigger conditions are met
        if should_place_order?(state, ticker_data, config) do
          place_auto_bid(state, config)
        else
          {:ok, state}
        end
      end
    end
  end

  defp should_place_order?(state, ticker_data, config) do
    trigger_price = config["trigger_price"]
    side = config["side"]
    current_price = get_price_for_side(ticker_data, side)

    # Check trigger condition
    trigger_met = case config["action"] do
      "buy" -> current_price >= trigger_price  # Price is at or above trigger
      "sell" -> current_price <= trigger_price  # Price is at or below trigger
    end

    # Check if we already have a pending order (in state)
    no_pending_orders = map_size(state.pending_orders) == 0

    # Check if we already have active/resting orders in the database
    no_active_orders = case Strategies.list_active_orders(state.strategy_id) do
      [] -> true
      orders ->
        # Check if any order is for the same market and at the same or similar price
        not Enum.any?(orders, fn order ->
          order.market_ticker == state.market_ticker &&
          order.status in ["pending", "resting"]
        end)
    end

    # Check cooldown
    cooldown_ok = check_cooldown(state)

    # Check risk limits
    risk_ok = check_risk_limits(state, config)

    if trigger_met && !no_pending_orders do
      Logger.debug("[Kalshi Strategy #{state.strategy_id}] Skipping - pending order exists")
    end

    if trigger_met && !no_active_orders do
      Logger.debug("[Kalshi Strategy #{state.strategy_id}] Skipping - active resting order exists")
    end

    trigger_met && no_pending_orders && no_active_orders && cooldown_ok && risk_ok
  end

  defp check_cooldown(state) do
    cooldown_seconds = get_in(state.strategy.risk_params, ["cooldown_seconds"]) || 60

    case state.last_trade_at do
      nil -> true
      last_trade ->
        DateTime.diff(DateTime.utc_now(), last_trade, :second) >= cooldown_seconds
    end
  end

  defp check_risk_limits(state, config) do
    max_position = config["max_contracts"] || 100
    risk_params = state.strategy.risk_params

    # Check max position size
    current_position = get_current_position_size(state.strategy_id, state.market_ticker)
    position_ok = current_position < max_position

    # Check daily loss limit
    daily_pnl = Strategies.todays_pnl()
    max_daily_loss = risk_params["max_daily_loss_cents"] || 5000
    daily_loss_ok = daily_pnl > -max_daily_loss

    # Check total exposure
    total_exposure = Strategies.total_exposure()
    max_exposure = risk_params["max_total_exposure_cents"] || 25000
    exposure_ok = total_exposure < max_exposure

    position_ok && daily_loss_ok && exposure_ok
  end

  defp get_current_position_size(strategy_id, market_ticker) do
    case Strategies.get_position_by_ticker(strategy_id, market_ticker) do
      nil -> 0
      position -> position.contracts
    end
  end

  defp place_auto_bid(state, config) do
    if state.paper_trading do
      Logger.info("[Kalshi Strategy #{state.strategy_id}] PAPER TRADE: Would place #{config["action"]} order")
      send_alert(state, :order_placed, %{
        paper_trading: true,
        side: config["side"],
        action: config["action"],
        price: config["target_price"],
        count: config["max_contracts"]
      })
      {:ok, state}
    else
      place_real_order(state, config)
    end
  end

  defp place_real_order(state, config) do
    # Build base order params (don't include time_in_force - Kalshi API rejects it)
    order_params = [
      side: config["side"],
      action: config["action"],
      count: config["max_contracts"],
      type: "limit",
      yes_price: if(config["side"] == "yes", do: config["target_price"], else: nil),
      no_price: if(config["side"] == "no", do: config["target_price"], else: nil),
      client_order_id: SofiTrader.Kalshi.Order.generate_client_order_id(state.strategy_id)
    ]

    case Orders.create_order(state.market_ticker, order_params) do
      {:ok, response} ->
        order_id = response["order"]["order_id"]
        Logger.info("[Kalshi Strategy #{state.strategy_id}] Order placed: #{order_id}")

        # Save order to database
        {:ok, db_order} = Strategies.create_order(%{
          strategy_id: state.strategy_id,
          order_id: order_id,
          client_order_id: order_params[:client_order_id],
          market_ticker: state.market_ticker,
          side: config["side"],
          action: config["action"],
          type: "limit",
          count: config["max_contracts"],
          price_cents: config["target_price"],
          status: "resting",
          placed_at: DateTime.utc_now()
        })

        # Track pending order
        new_pending = Map.put(state.pending_orders, order_id, db_order)

        # Send alert
        send_alert(state, :order_placed, %{
          order_id: order_id,
          side: config["side"],
          action: config["action"],
          price: config["target_price"],
          count: config["max_contracts"]
        })

        {:ok, %{state | pending_orders: new_pending, last_trade_at: DateTime.utc_now()}}

      {:error, reason} ->
        Logger.error("[Kalshi Strategy #{state.strategy_id}] Order failed: #{inspect(reason)}")
        send_alert(state, :error, %{message: "Order placement failed", reason: inspect(reason)})
        {:error, reason}
    end
  end

  defp handle_fill(state, order, fill_data) do
    # Create or update position
    case Strategies.get_position_by_ticker(state.strategy_id, state.market_ticker) do
      nil ->
        # Create new position
        Strategies.create_position(%{
          strategy_id: state.strategy_id,
          market_ticker: state.market_ticker,
          side: order.side,
          contracts: fill_data["count"],
          avg_price_cents: fill_data["price"],
          status: "open",
          opened_at: DateTime.utc_now()
        })

      position ->
        # Update existing position
        new_contracts = position.contracts + fill_data["count"]
        new_avg = calculate_new_average(
          position.contracts, position.avg_price_cents,
          fill_data["count"], fill_data["price"]
        )

        Strategies.update_position(position, %{
          contracts: new_contracts,
          avg_price_cents: new_avg
        })
    end

    # Send fill alert
    send_alert(state, :order_filled, %{
      order_id: order.order_id,
      filled_count: fill_data["count"],
      price: fill_data["price"]
    })
  end

  defp calculate_new_average(old_count, old_avg, new_count, new_price) do
    total_value = (old_count * old_avg) + (new_count * new_price)
    total_count = old_count + new_count
    div(total_value, total_count)
  end

  ## Alert Helpers

  defp maybe_send_alert(state, type, data) do
    cooldown = get_in(state.strategy.alert_config, ["alert_cooldown_seconds"]) || 300

    case state.last_alert_at do
      nil ->
        send_alert(state, type, data)

      last_alert ->
        if DateTime.diff(DateTime.utc_now(), last_alert, :second) >= cooldown do
          send_alert(state, type, data)
        else
          state
        end
    end
  end

  defp send_alert(state, type, data) do
    alert_config = state.strategy.alert_config || %{}
    channels = alert_config["channels"] || ["pubsub", "ui"]

    # Build alert
    alert_attrs = build_alert_attrs(state, type, data)
    |> Map.put(:channels_sent, channels)

    # Save to database
    {:ok, alert} = Strategies.create_alert(alert_attrs)

    # Broadcast via PubSub
    if "pubsub" in channels do
      Phoenix.PubSub.broadcast(
        SofiTrader.PubSub,
        "kalshi:alerts",
        {:new_alert, alert}
      )

      Phoenix.PubSub.broadcast(
        SofiTrader.PubSub,
        "kalshi:alerts:#{state.strategy_id}",
        {:new_alert, alert}
      )
    end

    # Send to webhook if configured
    if "webhook" in channels && alert_config["webhook_url"] do
      send_webhook(alert_config["webhook_url"], alert)
    end

    Logger.info("[Kalshi Strategy #{state.strategy_id}] Alert: #{alert.message}")

    # Update last alert time
    %{state | last_alert_at: DateTime.utc_now()}
  end

  defp build_alert_attrs(state, :price_threshold, data) do
    Alert.price_threshold(
      state.strategy_id,
      state.market_ticker,
      data.side,
      data.price,
      data.threshold,
      data.direction
    )
  end

  defp build_alert_attrs(state, :volume_spike, data) do
    Alert.volume_spike(
      state.strategy_id,
      state.market_ticker,
      data.volume,
      data.threshold
    )
  end

  defp build_alert_attrs(state, :price_change, data) do
    %{
      strategy_id: state.strategy_id,
      market_ticker: state.market_ticker,
      alert_type: "price_change",
      severity: "info",
      message: "Price changed #{data.change_pct}%: #{data.from_price}¢ → #{data.to_price}¢",
      data: data
    }
  end

  defp build_alert_attrs(state, :order_placed, data) do
    %{
      strategy_id: state.strategy_id,
      market_ticker: state.market_ticker,
      alert_type: "order_placed",
      severity: "info",
      message: "Order placed: #{data.action} #{data.count} #{String.upcase(data.side)} @ #{data.price}¢",
      data: data
    }
  end

  defp build_alert_attrs(state, :order_filled, data) do
    %{
      strategy_id: state.strategy_id,
      market_ticker: state.market_ticker,
      alert_type: "order_filled",
      severity: "info",
      message: "Order filled: #{data.filled_count} contracts @ #{data.price}¢",
      data: data
    }
  end

  defp build_alert_attrs(state, :error, data) do
    Alert.error(state.strategy_id, state.market_ticker, data.message, data)
  end

  defp send_webhook(url, alert) do
    # Fire and forget webhook
    Task.start(fn ->
      payload = %{
        strategy_id: alert.strategy_id,
        market_ticker: alert.market_ticker,
        alert_type: alert.alert_type,
        severity: alert.severity,
        message: alert.message,
        data: alert.data,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      case Req.post(url, json: payload) do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning("[Kalshi Alert] Webhook failed: #{inspect(reason)}")
      end
    end)
  end

  defp get_price_for_side(ticker_data, "yes"), do: ticker_data.yes_bid || ticker_data.yes_ask || 50
  defp get_price_for_side(ticker_data, "no"), do: ticker_data.no_bid || ticker_data.no_ask || 50
  defp get_price_for_side(_, _), do: 50
end
