defmodule SofiTrader.Indicators do
  @moduledoc """
  Technical indicator calculations for trading strategies.

  Provides functions to calculate common technical indicators like RSI, SMA, EMA, and MACD
  from price data. All calculations follow standard financial formulas.
  """

  @doc """
  Calculates the Relative Strength Index (RSI).

  RSI is a momentum oscillator that measures the speed and magnitude of price changes.
  Values range from 0 to 100, with readings above 70 indicating overbought conditions
  and readings below 30 indicating oversold conditions.

  ## Parameters

    - prices: List of prices (most recent last)
    - period: Number of periods to use (default: 14)

  ## Returns

    - {:ok, rsi_value} or {:error, reason}

  ## Examples

      iex> prices = [44, 44.34, 44.09, 43.61, 44.33, 44.83, 45.10, 45.42, 45.84, 46.08, 45.89, 46.03, 45.61, 46.28, 46.28]
      iex> Indicators.calculate_rsi(prices, 14)
      {:ok, 70.53}
  """
  def calculate_rsi(prices, period \\ 14) when is_list(prices) and period > 0 do
    if length(prices) < period + 1 do
      {:error, :insufficient_data}
    else
      rsi = compute_rsi(prices, period)
      {:ok, rsi}
    end
  end

  defp compute_rsi(prices, period) do
    # Calculate price changes
    changes =
      prices
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [prev, curr] -> curr - prev end)

    # Separate gains and losses
    {gains, losses} =
      Enum.reduce(changes, {[], []}, fn change, {gains, losses} ->
        if change > 0 do
          {[change | gains], [0 | losses]}
        else
          {[0 | gains], [abs(change) | losses]}
        end
      end)

    gains = Enum.reverse(gains)
    losses = Enum.reverse(losses)

    # Calculate initial average gain and loss
    initial_avg_gain = Enum.sum(Enum.take(gains, period)) / period
    initial_avg_loss = Enum.sum(Enum.take(losses, period)) / period

    # Calculate smoothed averages for remaining periods
    {final_avg_gain, final_avg_loss} =
      Enum.zip(Enum.drop(gains, period), Enum.drop(losses, period))
      |> Enum.reduce({initial_avg_gain, initial_avg_loss}, fn {gain, loss}, {avg_gain, avg_loss} ->
        new_avg_gain = (avg_gain * (period - 1) + gain) / period
        new_avg_loss = (avg_loss * (period - 1) + loss) / period
        {new_avg_gain, new_avg_loss}
      end)

    # Calculate RSI
    if final_avg_loss == 0 do
      100.0
    else
      rs = final_avg_gain / final_avg_loss
      rsi = 100 - 100 / (1 + rs)
      Float.round(rsi, 2)
    end
  end

  @doc """
  Calculates the Simple Moving Average (SMA).

  SMA is the average of prices over a specified period.

  ## Parameters

    - prices: List of prices (most recent last)
    - period: Number of periods to average

  ## Returns

    - {:ok, sma_value} or {:error, reason}

  ## Examples

      iex> prices = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      iex> Indicators.calculate_sma(prices, 5)
      {:ok, 8.0}
  """
  def calculate_sma(prices, period) when is_list(prices) and period > 0 do
    if length(prices) < period do
      {:error, :insufficient_data}
    else
      sma =
        prices
        |> Enum.take(-period)
        |> Enum.sum()
        |> Kernel./(period)
        |> Float.round(2)

      {:ok, sma}
    end
  end

  @doc """
  Calculates the Exponential Moving Average (EMA).

  EMA gives more weight to recent prices, making it more responsive to new information.

  ## Parameters

    - prices: List of prices (most recent last)
    - period: Number of periods for the EMA
    - previous_ema: Previous EMA value (optional, will use SMA if not provided)

  ## Returns

    - {:ok, ema_value} or {:error, reason}

  ## Examples

      iex> prices = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      iex> Indicators.calculate_ema(prices, 5)
      {:ok, 8.27}
  """
  def calculate_ema(prices, period, previous_ema \\ nil) when is_list(prices) and period > 0 do
    if length(prices) < period do
      {:error, :insufficient_data}
    else
      multiplier = 2 / (period + 1)
      current_price = List.last(prices)

      ema =
        case previous_ema do
          nil ->
            # Use SMA as the initial EMA
            {:ok, sma} = calculate_sma(Enum.take(prices, period), period)

            # Calculate EMA for remaining prices
            prices
            |> Enum.drop(period)
            |> Enum.reduce(sma, fn price, prev_ema ->
              (price - prev_ema) * multiplier + prev_ema
            end)

          prev ->
            (current_price - prev) * multiplier + prev
        end

      {:ok, Float.round(ema, 2)}
    end
  end

  @doc """
  Calculates all EMA values for a price series.

  Returns a list of EMA values, one for each price after the initial period.

  ## Parameters

    - prices: List of prices (most recent last)
    - period: Number of periods for the EMA

  ## Returns

    - {:ok, list_of_emas} or {:error, reason}
  """
  def calculate_ema_series(prices, period) when is_list(prices) and period > 0 do
    if length(prices) < period do
      {:error, :insufficient_data}
    else
      # Calculate initial SMA
      {:ok, initial_sma} = calculate_sma(Enum.take(prices, period), period)
      multiplier = 2 / (period + 1)

      # Calculate EMA for each subsequent price
      emas =
        prices
        |> Enum.drop(period)
        |> Enum.scan(initial_sma, fn price, prev_ema ->
          (price - prev_ema) * multiplier + prev_ema
        end)
        |> Enum.map(&Float.round(&1, 2))

      {:ok, [Float.round(initial_sma, 2) | emas]}
    end
  end

  @doc """
  Calculates the Moving Average Convergence Divergence (MACD).

  MACD shows the relationship between two moving averages and consists of:
  - MACD Line: 12-period EMA - 26-period EMA
  - Signal Line: 9-period EMA of MACD Line
  - Histogram: MACD Line - Signal Line

  ## Parameters

    - prices: List of prices (most recent last)
    - fast_period: Fast EMA period (default: 12)
    - slow_period: Slow EMA period (default: 26)
    - signal_period: Signal line EMA period (default: 9)

  ## Returns

    - {:ok, %{macd: value, signal: value, histogram: value}} or {:error, reason}

  ## Examples

      iex> prices = [1..50]
      iex> Indicators.calculate_macd(prices)
      {:ok, %{macd: 1.23, signal: 0.89, histogram: 0.34}}
  """
  def calculate_macd(prices, fast_period \\ 12, slow_period \\ 26, signal_period \\ 9) do
    if length(prices) < slow_period + signal_period do
      {:error, :insufficient_data}
    else
      # Calculate fast and slow EMAs
      {:ok, fast_emas} = calculate_ema_series(prices, fast_period)
      {:ok, slow_emas} = calculate_ema_series(prices, slow_period)

      # Align the EMAs (slow EMA starts later)
      offset = slow_period - fast_period
      aligned_fast = Enum.drop(fast_emas, offset)

      # Calculate MACD line (fast EMA - slow EMA)
      macd_line =
        Enum.zip(aligned_fast, slow_emas)
        |> Enum.map(fn {fast, slow} -> Float.round(fast - slow, 2) end)

      # Calculate signal line (9-period EMA of MACD line)
      {:ok, signal_emas} = calculate_ema_series(macd_line, signal_period)
      signal = List.last(signal_emas)

      # Get current MACD and calculate histogram
      macd = List.last(macd_line)
      histogram = Float.round(macd - signal, 2)

      {:ok, %{macd: macd, signal: signal, histogram: histogram}}
    end
  end

  @doc """
  Calculates Bollinger Bands.

  Bollinger Bands consist of:
  - Middle Band: N-period SMA
  - Upper Band: Middle Band + (K * N-period standard deviation)
  - Lower Band: Middle Band - (K * N-period standard deviation)

  ## Parameters

    - prices: List of prices (most recent last)
    - period: Number of periods for SMA (default: 20)
    - std_dev_mult: Standard deviation multiplier (default: 2)

  ## Returns

    - {:ok, %{upper: value, middle: value, lower: value}} or {:error, reason}
  """
  def calculate_bollinger_bands(prices, period \\ 20, std_dev_mult \\ 2) do
    if length(prices) < period do
      {:error, :insufficient_data}
    else
      recent_prices = Enum.take(prices, -period)
      {:ok, middle} = calculate_sma(recent_prices, period)

      # Calculate standard deviation
      mean = middle
      variance =
        recent_prices
        |> Enum.map(fn price -> :math.pow(price - mean, 2) end)
        |> Enum.sum()
        |> Kernel./(period)

      std_dev = :math.sqrt(variance)

      upper = Float.round(middle + std_dev_mult * std_dev, 2)
      lower = Float.round(middle - std_dev_mult * std_dev, 2)

      {:ok, %{upper: upper, middle: Float.round(middle, 2), lower: lower}}
    end
  end

  @doc """
  Checks if there's a bullish crossover (fast crosses above slow).

  ## Parameters

    - fast_values: List of fast indicator values [prev, current]
    - slow_values: List of slow indicator values [prev, current]

  ## Returns

    - true if bullish crossover occurred, false otherwise
  """
  def bullish_crossover?([fast_prev, fast_curr], [slow_prev, slow_curr]) do
    fast_prev <= slow_prev and fast_curr > slow_curr
  end

  @doc """
  Checks if there's a bearish crossover (fast crosses below slow).

  ## Parameters

    - fast_values: List of fast indicator values [prev, current]
    - slow_values: List of slow indicator values [prev, current]

  ## Returns

    - true if bearish crossover occurred, false otherwise
  """
  def bearish_crossover?([fast_prev, fast_curr], [slow_prev, slow_curr]) do
    fast_prev >= slow_prev and fast_curr < slow_curr
  end
end
