defmodule SofiTrader.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Conditionally start WebSocketManager based on sandbox mode
    # WebSocket streaming is not available in Tradier sandbox (paper trading)
    tradier_websocket = if tradier_sandbox_mode?() do
      []
    else
      [SofiTrader.MarketData.WebSocketManager]
    end

    # Conditionally start Kalshi WebSocketManager if API is configured
    kalshi_websocket = if kalshi_configured?() do
      [SofiTrader.Kalshi.WebSocketManager]
    else
      []
    end

    # Conditionally start AI Sports Scanner if OpenAI API is configured
    ai_scanner = if openai_configured?() do
      [SofiTrader.AI.SportsOpportunityScanner]
    else
      []
    end

    children = [
      SofiTraderWeb.Telemetry,
      SofiTrader.Repo,
      {DNSCluster, query: Application.get_env(:sofi_trader, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SofiTrader.PubSub},
      # Tradier strategy system
      {Registry, keys: :unique, name: SofiTrader.StrategyRegistry},
      SofiTrader.Strategies.Supervisor,
      # Tradier market data system
      {Registry, keys: :unique, name: SofiTrader.MarketDataRegistry},
      SofiTrader.MarketData.PriceStore,
      SofiTrader.MarketData.QuoteCache
    ] ++ tradier_websocket ++ [
      SofiTrader.MarketData.Supervisor,
      # Kalshi prediction markets system
      {Registry, keys: :unique, name: SofiTrader.KalshiStrategyRegistry},
      SofiTrader.Kalshi.StrategySupervisor
    ] ++ kalshi_websocket ++ ai_scanner ++ [
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
        SofiTrader.Kalshi.StrategySupervisor.start_all_active(paper_trading: true)
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

  defp tradier_sandbox_mode? do
    config = Application.get_env(:sofi_trader, :tradier, [])
    Keyword.get(config, :sandbox, true)
  end

  defp kalshi_configured? do
    api_key = System.get_env("KALSHI_API_KEY")
    private_key = System.get_env("KALSHI_PRIVATE_KEY")

    is_binary(api_key) and byte_size(api_key) > 0 and
    is_binary(private_key) and byte_size(private_key) > 0
  end

  defp openai_configured? do
    api_key = System.get_env("OPENAI_API_KEY")
    is_binary(api_key) and byte_size(api_key) > 0
  end
end
