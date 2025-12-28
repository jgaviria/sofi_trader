defmodule SofiTrader.AI.SportsOpportunityScanner do
  @moduledoc """
  GenServer that periodically scans sports markets for AI-identified opportunities.

  Runs the sports scanner and analyzer pipeline on a configurable interval,
  broadcasting opportunities via PubSub and storing them for the dashboard.

  ## Usage

      # Start via application supervisor (recommended)
      # Or manually:
      {:ok, pid} = SportsOpportunityScanner.start_link()

      # Trigger immediate scan
      SportsOpportunityScanner.scan_now()

      # Get latest opportunities
      SportsOpportunityScanner.get_opportunities()

  ## Configuration

      config :sofi_trader, SofiTrader.AI.SportsOpportunityScanner,
        scan_interval_ms: 300_000,  # 5 minutes
        min_confidence: 0.65,
        min_edge: 5
  """

  use GenServer
  require Logger

  alias SofiTrader.AI.{SportsScanner, SportsAnalyzer, OpenAIClient}
  alias SofiTrader.Kalshi.{Alert, Strategies}

  @default_scan_interval 5 * 60 * 1000  # 5 minutes
  @default_min_confidence 0.65
  @default_min_edge 5
  @max_markets_per_scan 10  # Limit API calls per scan

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger an immediate scan.
  """
  def scan_now do
    GenServer.cast(__MODULE__, :scan_now)
  end

  @doc """
  Get the latest opportunities found by the scanner.
  """
  def get_opportunities do
    GenServer.call(__MODULE__, :get_opportunities)
  end

  @doc """
  Get the current scanner status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Update scanner configuration.
  """
  def configure(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end

  @doc """
  Enable or disable the scanner.
  """
  def set_enabled(enabled) when is_boolean(enabled) do
    GenServer.call(__MODULE__, {:set_enabled, enabled})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    config = Application.get_env(:sofi_trader, __MODULE__, [])

    state = %{
      enabled: Keyword.get(opts, :enabled, false),  # Disabled by default - manual analysis only
      scan_interval: Keyword.get(config, :scan_interval_ms, @default_scan_interval),
      min_confidence: Keyword.get(config, :min_confidence, @default_min_confidence),
      min_edge: Keyword.get(config, :min_edge, @default_min_edge),
      last_scan_at: nil,
      last_scan_result: nil,
      opportunities: [],
      total_scans: 0,
      total_opportunities_found: 0,
      scanning: false,
      api_configured: OpenAIClient.configured?()
    }

    # Only schedule auto-scan if explicitly enabled
    if state.enabled && state.api_configured do
      schedule_scan(state.scan_interval)
      Logger.info("[SportsOpportunityScanner] Auto-scan enabled with #{state.scan_interval}ms interval")
    else
      if state.api_configured do
        Logger.info("[SportsOpportunityScanner] Started in manual mode - click Analyze to analyze markets")
      else
        Logger.warning("[SportsOpportunityScanner] OpenAI API not configured")
      end
    end

    {:ok, state}
  end

  @impl true
  def handle_cast(:scan_now, state) do
    if state.scanning do
      Logger.debug("[SportsOpportunityScanner] Scan already in progress, skipping")
      {:noreply, state}
    else
      {:noreply, do_scan(state)}
    end
  end

  @impl true
  def handle_call(:get_opportunities, _from, state) do
    {:reply, state.opportunities, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      scanning: state.scanning,
      api_configured: state.api_configured,
      last_scan_at: state.last_scan_at,
      scan_interval_ms: state.scan_interval,
      min_confidence: state.min_confidence,
      min_edge: state.min_edge,
      opportunities_count: length(state.opportunities),
      total_scans: state.total_scans,
      total_opportunities_found: state.total_opportunities_found
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call({:configure, opts}, _from, state) do
    new_state = %{state |
      min_confidence: Keyword.get(opts, :min_confidence, state.min_confidence),
      min_edge: Keyword.get(opts, :min_edge, state.min_edge),
      scan_interval: Keyword.get(opts, :scan_interval_ms, state.scan_interval)
    }
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    new_state = %{state | enabled: enabled}

    if enabled && !state.enabled && state.api_configured do
      schedule_scan(state.scan_interval)
      Logger.info("[SportsOpportunityScanner] Scanner enabled")
    end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:scheduled_scan, state) do
    new_state = if state.enabled && state.api_configured && !state.scanning do
      # Schedule next scan
      schedule_scan(state.scan_interval)
      do_scan(state)
    else
      if state.enabled && state.api_configured do
        schedule_scan(state.scan_interval)
      end
      state
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:scan_complete, result}, state) do
    new_state = %{state |
      scanning: false,
      last_scan_at: DateTime.utc_now(),
      last_scan_result: result
    }

    new_state = case result do
      {:ok, opportunities} ->
        Logger.info("[SportsOpportunityScanner] Scan complete: #{length(opportunities)} opportunities found")

        # Broadcast and store opportunities
        broadcast_opportunities(opportunities)

        %{new_state |
          opportunities: opportunities,
          total_opportunities_found: state.total_opportunities_found + length(opportunities)
        }

      {:error, reason} ->
        Logger.error("[SportsOpportunityScanner] Scan failed: #{inspect(reason)}")
        new_state
    end

    {:noreply, new_state}
  end

  # Private Functions

  defp schedule_scan(interval) do
    Process.send_after(self(), :scheduled_scan, interval)
  end

  defp do_scan(state) do
    Logger.info("[SportsOpportunityScanner] Starting scan...")

    # Run scan in a separate process to not block the GenServer
    parent = self()

    spawn(fn ->
      result = run_scan_pipeline(state)
      send(parent, {:scan_complete, result})
    end)

    %{state | scanning: true, total_scans: state.total_scans + 1}
  end

  defp run_scan_pipeline(state) do
    with {:ok, markets} <- SportsScanner.scan(limit: 100),
         markets_to_analyze <- Enum.take(markets, @max_markets_per_scan),
         {:ok, opportunities} <- analyze_markets(markets_to_analyze, state) do
      {:ok, opportunities}
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  defp analyze_markets([], _state), do: {:ok, []}
  defp analyze_markets(markets, state) do
    Logger.info("[SportsOpportunityScanner] Analyzing #{length(markets)} markets...")

    results =
      markets
      |> Enum.map(fn market ->
        # Add a small delay between API calls to avoid rate limiting
        Process.sleep(500)

        case SportsAnalyzer.analyze(market) do
          {:ok, analysis} ->
            if should_alert?(analysis, state) do
              {market, analysis}
            else
              nil
            end

          {:error, reason} ->
            Logger.warning("[SportsOpportunityScanner] Analysis failed for #{market.ticker}: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {_market, analysis} -> -analysis.edge end)

    {:ok, results}
  end

  defp should_alert?(analysis, state) do
    analysis.recommendation != :skip &&
    analysis.confidence >= state.min_confidence &&
    analysis.edge >= state.min_edge
  end

  defp broadcast_opportunities(opportunities) do
    Enum.each(opportunities, fn {market, analysis} ->
      # Build and broadcast alert
      alert_attrs = Alert.ai_opportunity(market.ticker, analysis)

      # Save to database
      case Strategies.create_alert(alert_attrs) do
        {:ok, alert} ->
          # Broadcast via PubSub
          Phoenix.PubSub.broadcast(
            SofiTrader.PubSub,
            "kalshi:alerts",
            {:new_alert, alert}
          )

          Phoenix.PubSub.broadcast(
            SofiTrader.PubSub,
            "ai:opportunities",
            {:new_opportunity, market, analysis, alert}
          )

          Logger.info("[SportsOpportunityScanner] Alert: #{alert.message}")

        {:error, reason} ->
          Logger.error("[SportsOpportunityScanner] Failed to save alert: #{inspect(reason)}")
      end
    end)
  end
end
