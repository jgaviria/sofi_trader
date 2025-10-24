defmodule SofiTrader.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SofiTraderWeb.Telemetry,
      SofiTrader.Repo,
      {DNSCluster, query: Application.get_env(:sofi_trader, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SofiTrader.PubSub},
      # Strategy system
      {Registry, keys: :unique, name: SofiTrader.StrategyRegistry},
      SofiTrader.Strategies.Supervisor,
      # Start a worker by calling: SofiTrader.Worker.start_link(arg)
      # {SofiTrader.Worker, arg},
      # Start to serve requests, typically the last entry
      SofiTraderWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SofiTrader.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SofiTraderWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
