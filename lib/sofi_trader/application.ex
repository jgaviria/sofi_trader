defmodule SofiTrader.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Conditionally start WebSocketManager based on sandbox mode
    # WebSocket streaming is not available in Tradier sandbox (paper trading)
    websocket_manager = if sandbox_mode?() do
      []
    else
      [SofiTrader.MarketData.WebSocketManager]
    end

    children = [
      SofiTraderWeb.Telemetry,
      SofiTrader.Repo,
      {DNSCluster, query: Application.get_env(:sofi_trader, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SofiTrader.PubSub},
      # Strategy system
      {Registry, keys: :unique, name: SofiTrader.StrategyRegistry},
      SofiTrader.Strategies.Supervisor,
      # Market data system
      {Registry, keys: :unique, name: SofiTrader.MarketDataRegistry}
    ] ++ websocket_manager ++ [
      SofiTrader.MarketData.Supervisor,
      # Start a worker by calling: SofiTrader.Worker.start_link(arg)
      # {SofiTrader.Worker, arg},
      # Start to serve requests, typically the last entry
      SofiTraderWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SofiTrader.Supervisor]

    with {:ok, supervisor_pid} <- Supervisor.start_link(children, opts) do
      # Auto-start all active strategies after supervisor is running
      Task.start(fn ->
        # Wait a moment for all systems to be ready
        Process.sleep(1000)
        SofiTrader.Strategies.Supervisor.start_all_active_strategies(paper_trading: true)
      end)

      {:ok, supervisor_pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SofiTraderWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp sandbox_mode? do
    config = Application.get_env(:sofi_trader, :tradier, [])
    Keyword.get(config, :sandbox, true)
  end
end
