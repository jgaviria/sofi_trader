defmodule SofiTrader.Trading.PositionManager do
  @moduledoc """
  Manages open trading positions.

  Tracks open positions, monitors for exit conditions, and handles position lifecycle.
  """

  use GenServer
  require Logger

  alias SofiTrader.Tradier.Trading

  defstruct [:account_id, :positions, :token]

  @doc """
  Start a new position manager.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Open a new position.
  """
  def open_position(pid, symbol, side, quantity, opts \\ []) do
    GenServer.call(pid, {:open_position, symbol, side, quantity, opts})
  end

  @doc """
  Close a position.
  """
  def close_position(pid, symbol) do
    GenServer.call(pid, {:close_position, symbol})
  end

  @doc """
  Get all open positions.
  """
  def get_positions(pid) do
    GenServer.call(pid, :get_positions)
  end

  @doc """
  Get a specific position.
  """
  def get_position(pid, symbol) do
    GenServer.call(pid, {:get_position, symbol})
  end

  @doc """
  Update position with current market data.
  """
  def update_position(pid, symbol, market_data) do
    GenServer.cast(pid, {:update_position, symbol, market_data})
  end

  # GenServer Callbacks

  @impl GenServer
  def init(opts) do
    account_id = Keyword.fetch!(opts, :account_id)
    token = Keyword.get(opts, :token) || System.get_env("TRADIER_ACCESS_TOKEN")

    state = %__MODULE__{
      account_id: account_id,
      positions: %{},
      token: token
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:open_position, symbol, side, quantity, opts}, _from, state) do
    # Prepare order parameters
    order_params = %{
      class: "equity",
      symbol: symbol,
      side: normalize_side(side),
      quantity: quantity,
      type: Keyword.get(opts, :order_type, "market"),
      duration: Keyword.get(opts, :duration, "day")
    }

    # Add price if limit order
    if order_params.type == "limit" do
      order_params = Map.put(order_params, :price, Keyword.fetch!(opts, :price))
    end

    # Place order
    case Trading.place_order(state.account_id, order_params, token: state.token) do
      {:ok, response} ->
        order_id = get_in(response, ["order", "id"])

        position = %{
          symbol: symbol,
          side: side,
          quantity: quantity,
          order_id: order_id,
          entry_price: nil,
          current_price: nil,
          pnl: 0,
          opened_at: DateTime.utc_now(),
          status: :pending
        }

        new_state = %{state | positions: Map.put(state.positions, symbol, position)}
        {:reply, {:ok, position}, new_state}

      {:error, error} ->
        Logger.error("Failed to open position for #{symbol}: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  @impl GenServer
  def handle_call({:close_position, symbol}, _from, state) do
    case Map.get(state.positions, symbol) do
      nil ->
        {:reply, {:error, :not_found}, state}

      position ->
        close_side = if position.side == :long, do: "sell", else: "buy_to_cover"

        order_params = %{
          class: "equity",
          symbol: symbol,
          side: close_side,
          quantity: position.quantity,
          type: "market",
          duration: "day"
        }

        case Trading.place_order(state.account_id, order_params, token: state.token) do
          {:ok, response} ->
            order_id = get_in(response, ["order", "id"])
            Logger.info("Closed position for #{symbol}, order ID: #{order_id}")

            new_state = %{state | positions: Map.delete(state.positions, symbol)}
            {:reply, {:ok, order_id}, new_state}

          {:error, error} ->
            Logger.error("Failed to close position for #{symbol}: #{inspect(error)}")
            {:reply, {:error, error}, state}
        end
    end
  end

  @impl GenServer
  def handle_call(:get_positions, _from, state) do
    {:reply, state.positions, state}
  end

  @impl GenServer
  def handle_call({:get_position, symbol}, _from, state) do
    position = Map.get(state.positions, symbol)
    {:reply, position, state}
  end

  @impl GenServer
  def handle_cast({:update_position, symbol, market_data}, state) do
    case Map.get(state.positions, symbol) do
      nil ->
        {:noreply, state}

      position ->
        current_price = market_data[:close] || market_data[:price]

        updated_position =
          position
          |> Map.put(:current_price, current_price)
          |> calculate_pnl()

        new_state = %{state | positions: Map.put(state.positions, symbol, updated_position)}
        {:noreply, new_state}
    end
  end

  # Private Functions

  defp normalize_side(:long), do: "buy"
  defp normalize_side(:short), do: "sell_short"
  defp normalize_side(side) when is_binary(side), do: side

  defp calculate_pnl(position) do
    if position.entry_price && position.current_price do
      pnl =
        case position.side do
          :long ->
            (position.current_price - position.entry_price) * position.quantity

          :short ->
            (position.entry_price - position.current_price) * position.quantity
        end

      Map.put(position, :pnl, pnl)
    else
      position
    end
  end
end
