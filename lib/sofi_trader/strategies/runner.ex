defmodule SofiTrader.Strategies.Runner do
  @moduledoc """
  GenServer that runs a trading strategy.

  Each active strategy has its own Runner process that:
  - Subscribes to market data for the symbol
  - Maintains price history for indicator calculations
  - Evaluates entry/exit conditions on each new candle
  - Executes trades via Tradier API
  - Updates positions and P&L
  - Enforces risk management rules

  The Runner is supervised and will automatically restart on failure.
  """

  use GenServer
  require Logger

  alias SofiTrader.{Strategies, RiskManager}
  alias SofiTrader.Strategies.Implementations.RsiMeanReversion
  alias SofiTrader.Tradier.{Trading, MarketData}

  # How many candles to keep in history
  @max_history_size 100

  defstruct [
    :strategy_id,
    :strategy,
    :price_history,
    :last_candle_time,
    :paper_trading
  ]

  ## Client API

  @doc """
  Starts a strategy runner.

  ## Options

    - strategy_id: The ID of the strategy to run
    - paper_trading: If true, simulates trades without actual execution (default: false)
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
  Forces an evaluation of the strategy (useful for testing).
  """
  def force_evaluation(strategy_id) do
    GenServer.call(via_tuple(strategy_id), :force_evaluation)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    strategy_id = Keyword.fetch!(opts, :strategy_id)
    paper_trading = Keyword.get(opts, :paper_trading, false)

    Logger.info("Starting Strategy Runner for strategy #{strategy_id}")

    # Load strategy from database
    strategy = Strategies.get_strategy!(strategy_id)

    # Validate strategy configuration
    case validate_strategy(strategy) do
      :ok ->
        # Subscribe to market data updates via Phoenix PubSub
        Phoenix.PubSub.subscribe(SofiTrader.PubSub, "market_data:#{strategy.symbol}")

        # Initialize state
        state = %__MODULE__{
          strategy_id: strategy_id,
          strategy: strategy,
          price_history: [],
          last_candle_time: nil,
          paper_trading: paper_trading
        }

        # Fetch initial price history
        {:ok, state, {:continue, :load_initial_data}}

      {:error, reason} ->
        Logger.error("Failed to start strategy #{strategy_id}: #{inspect(reason)}")
        {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_continue(:load_initial_data, state) do
    # Fetch recent candles for the symbol
    config = state.strategy.config
    timeframe = Map.get(config, "timeframe", "5min")

    case fetch_initial_candles(state.strategy.symbol, timeframe) do
      {:ok, candles} ->
        price_history = Enum.map(candles, & &1["close"])
        Logger.info("Loaded #{length(price_history)} candles for #{state.strategy.symbol}")

        {:noreply, %{state | price_history: price_history}}

      {:error, reason} ->
        Logger.warning("Could not load initial candles: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:force_evaluation, _from, state) do
    case evaluate_strategy(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:candle_closed, candle, price_history}, state) do
    # New candle data received from aggregator
    Logger.info(
      "Strategy #{state.strategy_id}: New candle for #{candle.symbol} " <>
        "O=#{candle.open} H=#{candle.high} L=#{candle.low} C=#{candle.close}"
    )

    # Use the price history from the aggregator (it's more reliable)
    state = %{state |
      price_history: price_history,
      last_candle_time: candle.end_time
    }

    # Reload strategy to get latest data (positions, stats, etc.)
    strategy = Strategies.get_strategy!(state.strategy_id)
    state = %{state | strategy: strategy}

    # Evaluate strategy logic
    case evaluate_strategy(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Strategy evaluation failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Fallback for old message format (backward compatibility)
  @impl true
  def handle_info({:candle_closed, candle}, state) when is_map(candle) do
    Logger.debug("Strategy #{state.strategy_id}: New candle for #{candle["symbol"]} (old format)")

    # Update price history
    new_history = update_price_history(state.price_history, candle["close"])
    state = %{state | price_history: new_history, last_candle_time: candle["time"]}

    # Reload strategy to get latest data (positions, stats, etc.)
    strategy = Strategies.get_strategy!(state.strategy_id)
    state = %{state | strategy: strategy}

    # Evaluate strategy logic
    case evaluate_strategy(state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Strategy evaluation failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:price_update, price_data}, state) do
    # Real-time price update (between candles)
    # Used to update open positions' current P&L
    current_price = price_data["last"] || price_data["price"]

    if current_price do
      update_open_positions(state.strategy_id, current_price)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp validate_strategy(strategy) do
    with :ok <- check_strategy_type(strategy.type),
         :ok <- check_strategy_status(strategy.status),
         :ok <- validate_strategy_config(strategy) do
      :ok
    end
  end

  defp check_strategy_type("rsi_mean_reversion"), do: :ok
  defp check_strategy_type("ma_crossover"), do: {:error, "MA Crossover not yet implemented"}
  defp check_strategy_type(type), do: {:error, "Unknown strategy type: #{type}"}

  defp check_strategy_status("active"), do: :ok
  defp check_strategy_status(status), do: {:error, "Strategy not active: #{status}"}

  defp validate_strategy_config(strategy) do
    case strategy.type do
      "rsi_mean_reversion" ->
        RsiMeanReversion.validate_config(strategy.config)

      _ ->
        :ok
    end
  end

  defp evaluate_strategy(state) do
    min_candles = RsiMeanReversion.min_candles_required(state.strategy.config)

    if length(state.price_history) < min_candles do
      Logger.debug("Not enough price history (#{length(state.price_history)}/#{min_candles})")
      {:ok, state}
    else
      # Check for existing positions
      open_positions = Strategies.list_open_positions(state.strategy_id)

      if Enum.empty?(open_positions) do
        # No open positions - check for entry signal
        evaluate_entry_signal(state)
      else
        # Have open positions - check for exit signals
        evaluate_exit_signals(state, open_positions)
      end
    end
  end

  defp evaluate_entry_signal(state) do
    strategy = state.strategy
    current_price = List.last(state.price_history)

    case RsiMeanReversion.check_entry_signal(state.price_history, strategy.config) do
      {:buy, signal_details} ->
        # Entry signal detected - check risk management
        case RiskManager.can_open_position?(strategy, strategy.symbol, current_price) do
          {:ok, risk_details} ->
            Logger.info(
              "Opening position: #{strategy.symbol} @ $#{current_price} (#{risk_details.position_size} shares)"
            )

            execute_entry_trade(state, risk_details, signal_details)

          {:error, reason} ->
            Logger.warning("Cannot open position: #{inspect(reason)}")
            {:ok, state}
        end

      {:hold, reason} ->
        Logger.debug("No entry signal: #{reason}")
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp evaluate_exit_signals(state, positions) do
    current_price = List.last(state.price_history)

    Enum.each(positions, fn position ->
      case RsiMeanReversion.check_exit_signal(
             state.price_history,
             current_price,
             position,
             state.strategy.config
           ) do
        {:sell, reason} ->
          Logger.info("Closing position: #{position.symbol} @ $#{current_price} (#{reason})")
          execute_exit_trade(state, position, current_price, reason)

        {:hold, _reason} ->
          # Update position with current price for P&L tracking
          Strategies.update_position_price(position, current_price)

        {:error, reason} ->
          Logger.error("Exit signal check failed: #{inspect(reason)}")
      end
    end)

    {:ok, state}
  end

  defp execute_entry_trade(state, risk_details, _signal_details) do
    strategy = state.strategy
    current_price = List.last(state.price_history)
    quantity = risk_details.position_size

    # Calculate stop-loss and take-profit
    {:ok, exit_prices} = RiskManager.calculate_exit_prices(strategy, current_price, "buy")

    if state.paper_trading do
      # Paper trading - simulate the trade
      Logger.info("[PAPER] Buy #{quantity} shares of #{strategy.symbol} @ $#{current_price}")
      create_paper_position(state, quantity, current_price, exit_prices)
    else
      # Real trading - execute via Tradier
      execute_real_entry_trade(state, quantity, current_price, exit_prices)
    end
  end

  defp execute_real_entry_trade(state, quantity, entry_price, exit_prices) do
    strategy = state.strategy

    order_params = %{
      class: "equity",
      symbol: strategy.symbol,
      side: "buy",
      quantity: quantity,
      type: "market",
      duration: "day"
    }

    account_id = get_account_id()
    token = get_token()

    case Trading.place_order(account_id, order_params, token: token) do
      {:ok, response} ->
        order_id = get_in(response, ["order", "id"])
        Logger.info("Order placed successfully: #{order_id}")

        # Create position record
        {:ok, position} =
          Strategies.create_position(%{
            strategy_id: strategy.id,
            symbol: strategy.symbol,
            side: "buy",
            quantity: quantity,
            entry_price: entry_price,
            current_price: entry_price,
            stop_loss_price: exit_prices.stop_loss,
            take_profit_price: exit_prices.take_profit
          })

        # Create trade record
        Strategies.create_trade(%{
          strategy_id: strategy.id,
          position_id: position.id,
          order_id: order_id,
          symbol: strategy.symbol,
          side: "buy",
          quantity: quantity,
          price: entry_price
        })

        {:ok, state}

      {:error, error} ->
        Logger.error("Failed to place order: #{inspect(error)}")
        {:error, error}
    end
  end

  defp create_paper_position(state, quantity, entry_price, exit_prices) do
    strategy = state.strategy

    {:ok, position} =
      Strategies.create_position(%{
        strategy_id: strategy.id,
        symbol: strategy.symbol,
        side: "buy",
        quantity: quantity,
        entry_price: entry_price,
        current_price: entry_price,
        stop_loss_price: exit_prices.stop_loss,
        take_profit_price: exit_prices.take_profit
      })

    Strategies.create_trade(%{
      strategy_id: strategy.id,
      position_id: position.id,
      order_id: "PAPER_#{:rand.uniform(1_000_000)}",
      symbol: strategy.symbol,
      side: "buy",
      quantity: quantity,
      price: entry_price
    })

    {:ok, state}
  end

  defp execute_exit_trade(state, position, exit_price, reason) do
    if state.paper_trading do
      Logger.info("[PAPER] Sell #{position.quantity} shares of #{position.symbol} @ $#{exit_price}")
      close_paper_position(state, position, exit_price, reason)
    else
      execute_real_exit_trade(state, position, exit_price, reason)
    end
  end

  defp execute_real_exit_trade(state, position, exit_price, reason) do
    order_params = %{
      class: "equity",
      symbol: position.symbol,
      side: "sell",
      quantity: position.quantity,
      type: "market",
      duration: "day"
    }

    account_id = get_account_id()
    token = get_token()

    case Trading.place_order(account_id, order_params, token: token) do
      {:ok, response} ->
        order_id = get_in(response, ["order", "id"])
        Logger.info("Exit order placed successfully: #{order_id}")

        # Close the position
        {:ok, closed_position} = Strategies.close_position(position, exit_price, reason)

        # Create exit trade record
        pnl = Decimal.to_float(closed_position.pnl)

        Strategies.create_trade(%{
          strategy_id: state.strategy_id,
          position_id: position.id,
          order_id: order_id,
          symbol: position.symbol,
          side: "sell",
          quantity: position.quantity,
          price: exit_price,
          pnl: pnl
        })

        # Update strategy stats
        Strategies.update_strategy_stats(state.strategy, pnl)

        :ok

      {:error, error} ->
        Logger.error("Failed to place exit order: #{inspect(error)}")
        {:error, error}
    end
  end

  defp close_paper_position(state, position, exit_price, reason) do
    {:ok, closed_position} = Strategies.close_position(position, exit_price, reason)
    pnl = Decimal.to_float(closed_position.pnl)

    Strategies.create_trade(%{
      strategy_id: state.strategy_id,
      position_id: position.id,
      order_id: "PAPER_#{:rand.uniform(1_000_000)}",
      symbol: position.symbol,
      side: "sell",
      quantity: position.quantity,
      price: exit_price,
      pnl: pnl
    })

    Strategies.update_strategy_stats(state.strategy, pnl)
    :ok
  end

  defp update_open_positions(strategy_id, current_price) do
    strategy_id
    |> Strategies.list_open_positions()
    |> Enum.each(fn position ->
      Strategies.update_position_price(position, current_price)
    end)
  end

  defp update_price_history(history, new_price) do
    updated = history ++ [new_price]

    if length(updated) > @max_history_size do
      Enum.drop(updated, 1)
    else
      updated
    end
  end

  defp fetch_initial_candles(symbol, timeframe) do
    # Fetch last 100 candles from Tradier
    token = get_token()

    # Map our timeframe to Tradier's interval parameter
    interval = map_timeframe_to_interval(timeframe)

    # Calculate date range (last 5 days for 5min candles)
    end_date = Date.utc_today()
    start_date = Date.add(end_date, -5)

    MarketData.get_timesales(symbol,
      interval: interval,
      start: start_date,
      end: end_date,
      session_filter: "all",
      token: token
    )
    |> case do
      {:ok, %{"series" => %{"data" => candles}}} when is_list(candles) ->
        # Take last 100 candles
        recent_candles = Enum.take(candles, -100)
        {:ok, recent_candles}

      {:ok, _response} ->
        {:error, :no_data}

      {:error, error} ->
        {:error, error}
    end
  end

  defp map_timeframe_to_interval("1min"), do: "1min"
  defp map_timeframe_to_interval("5min"), do: "5min"
  defp map_timeframe_to_interval("15min"), do: "15min"
  defp map_timeframe_to_interval("daily"), do: "daily"
  defp map_timeframe_to_interval(_), do: "5min"

  defp get_account_id do
    System.get_env("TRADIER_ACCOUNT_ID") || "VA35810079"
  end

  defp get_token do
    System.get_env("TRADIER_ACCESS_TOKEN")
  end

  defp via_tuple(strategy_id) do
    {:via, Registry, {SofiTrader.StrategyRegistry, strategy_id}}
  end
end
