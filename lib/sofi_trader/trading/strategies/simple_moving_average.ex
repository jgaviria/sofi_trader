defmodule SofiTrader.Trading.Strategies.SimpleMovingAverage do
  @moduledoc """
  Simple Moving Average (SMA) crossover strategy.

  Generates buy signals when short-term SMA crosses above long-term SMA,
  and sell signals when short-term SMA crosses below long-term SMA.
  """

  @behaviour SofiTrader.Trading.Strategy

  defstruct [:short_period, :long_period, :position_size_pct, :price_history, :last_signal]

  @impl true
  def init(config) do
    state = %__MODULE__{
      short_period: Map.get(config, :short_period, 10),
      long_period: Map.get(config, :long_period, 30),
      position_size_pct: Map.get(config, :position_size_pct, 0.1),
      price_history: [],
      last_signal: :hold
    }

    {:ok, state}
  end

  @impl true
  def analyze(market_data, state) do
    price = market_data[:close] || market_data[:price]

    # Add new price to history
    price_history = [price | state.price_history] |> Enum.take(state.long_period)
    state = %{state | price_history: price_history}

    # Need enough data points
    if length(price_history) < state.long_period do
      {:hold, state}
    else
      short_sma = calculate_sma(price_history, state.short_period)
      long_sma = calculate_sma(price_history, state.long_period)

      signal = determine_signal(short_sma, long_sma, state.last_signal)
      new_state = %{state | last_signal: signal}

      {signal, new_state}
    end
  end

  @impl true
  def position_size(_signal, market_data, state) do
    # Calculate position size based on account balance and configured percentage
    account_balance = market_data[:account_balance] || 10000
    price = market_data[:close] || market_data[:price]

    max_position_value = account_balance * state.position_size_pct
    round(max_position_value / price)
  end

  @impl true
  def should_close?(position, market_data, state) do
    price = market_data[:close] || market_data[:price]

    # Update price history
    price_history = [price | state.price_history] |> Enum.take(state.long_period)

    if length(price_history) < state.long_period do
      false
    else
      short_sma = calculate_sma(price_history, state.short_period)
      long_sma = calculate_sma(price_history, state.long_period)

      # Close long position if short SMA crosses below long SMA
      # Close short position if short SMA crosses above long SMA
      case position.side do
        :long -> short_sma < long_sma
        :short -> short_sma > long_sma
        _ -> false
      end
    end
  end

  defp calculate_sma(prices, period) do
    prices
    |> Enum.take(period)
    |> Enum.sum()
    |> Kernel./(period)
  end

  defp determine_signal(short_sma, long_sma, last_signal) do
    cond do
      short_sma > long_sma and last_signal != :buy -> :buy
      short_sma < long_sma and last_signal != :sell -> :sell
      true -> :hold
    end
  end
end
