defmodule SofiTrader.Trading.Strategy do
  @moduledoc """
  Behaviour for trading strategies.

  All trading strategies should implement this behaviour.
  """

  @type signal :: :buy | :sell | :hold
  @type market_data :: map()
  @type position :: map()
  @type config :: map()

  @doc """
  Initialize the strategy with configuration.
  """
  @callback init(config) :: {:ok, any()} | {:error, any()}

  @doc """
  Analyze market data and generate a trading signal.
  """
  @callback analyze(market_data, state :: any()) :: {signal, any()}

  @doc """
  Calculate position size for a trade.
  """
  @callback position_size(signal, market_data, state :: any()) :: non_neg_integer()

  @doc """
  Determine if should close position.
  """
  @callback should_close?(position, market_data, state :: any()) :: boolean()
end
