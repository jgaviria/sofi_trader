defmodule SofiTrader.Strategies.Implementations.RsiMeanReversion do
  @moduledoc """
  RSI Mean Reversion Trading Strategy.

  This strategy buys when RSI indicates oversold conditions (RSI < 30)
  and sells when RSI indicates overbought conditions (RSI > 70) or when
  stop-loss/take-profit targets are hit.

  ## Strategy Logic

  Entry Signal (Buy):
  - RSI drops below oversold threshold (default: 30)
  - No existing position for this symbol
  - Risk management checks pass

  Exit Signal (Sell):
  - RSI rises above overbought threshold (default: 70), OR
  - Stop-loss is hit, OR
  - Take-profit is hit

  ## Configuration

  Required config parameters:
  - rsi_period: Number of periods for RSI calculation (default: 14)
  - oversold_threshold: RSI level for buy signal (default: 30)
  - overbought_threshold: RSI level for sell signal (default: 70)
  - timeframe: Candle timeframe (default: "5min")
  """

  alias SofiTrader.Indicators
  require Logger

  @doc """
  Analyzes current market data and determines if entry signal is present.

  ## Parameters

    - price_history: List of recent closing prices
    - config: Strategy configuration map

  ## Returns

    - {:buy, details} if buy signal detected
    - {:hold, reason} if no signal or conditions not met
    - {:error, reason} if analysis fails
  """
  def check_entry_signal(price_history, config) do
    rsi_period = Map.get(config, "rsi_period", 14)
    oversold_threshold = Map.get(config, "oversold_threshold", 30)

    case Indicators.calculate_rsi(price_history, rsi_period) do
      {:ok, rsi} when rsi < oversold_threshold ->
        Logger.info("RSI Mean Reversion: Buy signal detected (RSI: #{rsi})")

        {:buy,
         %{
           rsi: rsi,
           current_price: List.last(price_history),
           signal_strength: calculate_signal_strength(rsi, oversold_threshold, :oversold)
         }}

      {:ok, rsi} ->
        {:hold, "RSI not oversold (#{rsi})"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Analyzes current position and determines if exit signal is present.

  ## Parameters

    - price_history: List of recent closing prices
    - current_price: Current market price
    - position: Position schema
    - config: Strategy configuration map

  ## Returns

    - {:sell, reason} if sell signal detected
    - {:hold, reason} if no exit signal
    - {:error, reason} if analysis fails
  """
  def check_exit_signal(price_history, current_price, position, config) do
    rsi_period = Map.get(config, "rsi_period", 14)
    overbought_threshold = Map.get(config, "overbought_threshold", 70)

    # First check stop-loss and take-profit (highest priority)
    updated_position = %{position | current_price: current_price}

    cond do
      SofiTrader.Strategies.Position.stop_loss_hit?(updated_position) ->
        Logger.warning("RSI Mean Reversion: Stop-loss hit for #{position.symbol}")
        {:sell, "stop_loss"}

      SofiTrader.Strategies.Position.take_profit_hit?(updated_position) ->
        Logger.info("RSI Mean Reversion: Take-profit hit for #{position.symbol}")
        {:sell, "take_profit"}

      true ->
        # Check RSI for overbought condition
        case Indicators.calculate_rsi(price_history, rsi_period) do
          {:ok, rsi} when rsi > overbought_threshold ->
            Logger.info("RSI Mean Reversion: Sell signal detected (RSI: #{rsi})")
            {:sell, "strategy_signal"}

          {:ok, rsi} ->
            {:hold, "RSI not overbought (#{rsi})"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Calculates the strength of the signal (0-100).

  Higher values indicate stronger signals. This can be used for position sizing
  or filtering weak signals.
  """
  def calculate_signal_strength(rsi, threshold, :oversold) do
    # For oversold: the lower the RSI below threshold, the stronger the signal
    # If RSI = 20 and threshold = 30, strength = (30-20)/30 * 100 = 33.3
    max(0, min(100, (threshold - rsi) / threshold * 100))
    |> Float.round(2)
  end

  def calculate_signal_strength(rsi, threshold, :overbought) do
    # For overbought: the higher the RSI above threshold, the stronger the signal
    # If RSI = 80 and threshold = 70, strength = (80-70)/(100-70) * 100 = 33.3
    max(0, min(100, (rsi - threshold) / (100 - threshold) * 100))
    |> Float.round(2)
  end

  @doc """
  Validates that the strategy configuration is correct.
  """
  def validate_config(config) do
    with {:ok, _} <- validate_rsi_period(config),
         {:ok, _} <- validate_thresholds(config),
         {:ok, _} <- validate_timeframe(config) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_rsi_period(%{"rsi_period" => period}) when is_integer(period) and period > 0,
    do: {:ok, period}

  defp validate_rsi_period(%{}), do: {:ok, 14}
  defp validate_rsi_period(_), do: {:error, "rsi_period must be a positive integer"}

  defp validate_thresholds(%{"oversold_threshold" => os, "overbought_threshold" => ob})
       when is_number(os) and is_number(ob) and os < ob and os > 0 and ob < 100,
       do: {:ok, {os, ob}}

  defp validate_thresholds(%{}), do: {:ok, {30, 70}}
  defp validate_thresholds(_), do: {:error, "invalid RSI thresholds"}

  defp validate_timeframe(%{"timeframe" => tf})
       when tf in ["1min", "5min", "15min", "30min", "1hour", "daily"],
       do: {:ok, tf}

  defp validate_timeframe(%{}), do: {:ok, "5min"}
  defp validate_timeframe(_), do: {:error, "invalid timeframe"}

  @doc """
  Returns a description of the strategy for display purposes.
  """
  def description do
    """
    RSI Mean Reversion Strategy

    Buys when RSI falls below oversold threshold (typically 30),
    indicating the asset may be undervalued. Sells when RSI rises
    above overbought threshold (typically 70) or when stop-loss/
    take-profit targets are hit.

    Best suited for: Range-bound markets, short-term trading
    Timeframe: 1min - 1hour (5min recommended)
    """
  end

  @doc """
  Returns the minimum number of candles needed for this strategy.
  """
  def min_candles_required(config) do
    rsi_period = Map.get(config, "rsi_period", 14)
    # Need at least period + 1 for RSI calculation
    rsi_period + 1
  end
end
