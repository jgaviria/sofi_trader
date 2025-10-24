defmodule SofiTrader.Tradier.Accounts do
  @moduledoc """
  Account operations for Tradier API.

  Provides functions to retrieve account information, balances, positions, history, etc.
  """

  alias SofiTrader.Tradier.Client

  @doc """
  Get user profile information.
  """
  def get_profile(opts \\ []) do
    Client.get("/user/profile", [], opts)
  end

  @doc """
  Get account balances.
  """
  def get_balances(account_id, opts \\ []) do
    Client.get("/accounts/#{account_id}/balances", [], opts)
  end

  @doc """
  Get account positions.
  """
  def get_positions(account_id, opts \\ []) do
    Client.get("/accounts/#{account_id}/positions", [], opts)
  end

  @doc """
  Get account history.
  """
  def get_history(account_id, opts \\ []) do
    params = build_history_params(opts)
    Client.get("/accounts/#{account_id}/history", params, opts)
  end

  @doc """
  Get gain/loss for an account.
  """
  def get_gainloss(account_id, opts \\ []) do
    params = build_gainloss_params(opts)
    Client.get("/accounts/#{account_id}/gainloss", params, opts)
  end

  @doc """
  Get orders for an account.
  """
  def get_orders(account_id, opts \\ []) do
    Client.get("/accounts/#{account_id}/orders", [], opts)
  end

  @doc """
  Get a specific order.
  """
  def get_order(account_id, order_id, opts \\ []) do
    Client.get("/accounts/#{account_id}/orders/#{order_id}", [], opts)
  end

  defp build_history_params(opts) do
    []
    |> maybe_add_param(:page, opts[:page])
    |> maybe_add_param(:limit, opts[:limit])
    |> maybe_add_param(:type, opts[:type])
    |> maybe_add_param(:start, opts[:start])
    |> maybe_add_param(:end, opts[:end])
  end

  defp build_gainloss_params(opts) do
    []
    |> maybe_add_param(:page, opts[:page])
    |> maybe_add_param(:limit, opts[:limit])
    |> maybe_add_param(:start, opts[:start])
    |> maybe_add_param(:end, opts[:end])
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]
end
