# SofiTrader

A high-performance automated trading platform built with Elixir and Phoenix, leveraging OTP principles for fault tolerance, concurrency, and scalability. Integrates with the Tradier API for real-time market data and trade execution.

## Features

### Trading Infrastructure
- **Tradier API Integration**: Full REST API client for account management, market data, and trading operations
- **Real-time Market Data**: WebSocket-based streaming for live quotes, trades, and market events
- **High-Performance Caching**: ETS-based storage with lock-free concurrent reads for blazing-fast data access
- **PubSub Architecture**: Real-time push updates to all connected clients, eliminating polling overhead
- **Candlestick Aggregation**: Real-time OHLC candle generation from tick data with configurable timeframes

### Strategy System
- **Modular Strategy Framework**: Behavior-based strategy implementation with hot code reloading
- **RSI Mean Reversion Strategy**: Production-ready strategy with configurable parameters and risk management
- **Strategy Management UI**: Create, configure, start/stop, and monitor strategies via web interface
- **Paper Trading**: Test strategies safely with Tradier's sandbox environment
- **Position Management**: Comprehensive position tracking with real-time P&L calculation
- **Trade History**: Complete audit trail of all executed trades

### Phoenix LiveView Dashboard
- **Real-time Market Data Dashboard**: Live quotes for multiple symbols with auto-refresh
- **Strategy Monitoring**: View running strategies, positions, trades, and performance metrics
- **Interactive Charts**: Price history and RSI indicator visualization
- **Responsive Design**: Clean, modern UI with Tailwind CSS and DaisyUI

### Architecture & Performance
- **OTP Supervision Trees**: Fault-tolerant process supervision with automatic restart
- **Dynamic Process Management**: Strategies run as isolated GenServer processes
- **Registry-based Discovery**: Efficient process lookup and communication
- **Concurrent Data Access**: ETS tables for lock-free reads from any process
- **Process Monitoring**: Automatic cleanup of dead processes and stale data

## Project Structure

```
lib/sofi_trader/
├── tradier/                          # Tradier API client modules
│   ├── client.ex                     # Base HTTP client with authentication
│   ├── accounts.ex                   # Account balance and profile operations
│   ├── market_data.ex                # Market data fetching (quotes, candles, history)
│   ├── trading.ex                    # Order placement and management
│   └── websocket.ex                  # WebSocket client for live streaming
├── market_data/                      # Market data processing
│   ├── websocket_manager.ex          # Manages single WebSocket connection for all symbols
│   ├── candle_aggregator.ex          # Aggregates tick data into OHLC candles
│   ├── quote_cache.ex                # Centralized quote fetching with PubSub broadcasting
│   ├── price_store.ex                # ETS-based high-performance price/candle storage
│   └── supervisor.ex                 # DynamicSupervisor for market data processes
├── strategies/                       # Strategy management
│   ├── strategy.ex                   # Strategy schema and database operations
│   ├── supervisor.ex                 # DynamicSupervisor for strategy runners
│   ├── runner.ex                     # GenServer that executes strategy logic
│   └── implementations/              # Strategy implementations
│       └── rsi_mean_reversion.ex     # RSI-based mean reversion strategy
└── application.ex                    # OTP application with supervision tree

lib/sofi_trader_web/
├── live/                             # Phoenix LiveView modules
│   ├── dashboard_live.ex             # Real-time market data dashboard
│   └── strategy_live/                # Strategy management UI
│       ├── index.ex                  # List and create strategies
│       └── show.ex                   # Monitor strategy performance
└── components/                       # Reusable LiveView components
    └── trade_modal.ex                # Trade execution modal
```

## Getting Started

### Prerequisites

- Elixir 1.16 or later
- PostgreSQL (for data persistence)
- Tradier API account (get one at https://tradier.com)

### Installation

1. Clone the repository:
```bash
git clone https://github.com/jgaviria/sofi_trader.git
cd sofi_trader
```

2. Install dependencies:
```bash
mix deps.get
```

3. Configure your database in `config/dev.exs`:
```elixir
config :sofi_trader, SofiTrader.Repo,
  username: "your_username",
  password: "your_password",
  database: "sofi_trader_dev"
```

4. Create and migrate your database:
```bash
mix ecto.setup
```

5. Set up your Tradier API credentials in `.env`:
```bash
export TRADIER_ACCESS_TOKEN="your_access_token"
export TRADIER_SANDBOX="true"  # Set to false for production trading
export TRADIER_ACCOUNT_ID="your_account_id"
```

6. Start the Phoenix server:
```bash
source .env && mix phx.server
# Or use the provided script:
./start.sh
```

Visit [`localhost:4000`](http://localhost:4000) to access the dashboard.

## Using the Platform

### Market Data Dashboard

Navigate to http://localhost:4000 to view real-time market quotes:
- Default symbols: AAPL, MSFT, GOOGL, TSLA, NVDA
- Add/remove symbols dynamically
- Auto-updates every 10 seconds via PubSub
- Buy/Sell buttons for quick trade execution

### Creating a Strategy

1. Navigate to "Strategies" in the top navigation
2. Click "New Strategy"
3. Configure your strategy:
   - **Name**: Descriptive name for your strategy
   - **Symbol**: Stock ticker to trade (e.g., AAPL)
   - **Type**: Select "RSI Mean Reversion"
   - **RSI Period**: Number of candles for RSI calculation (default: 14)
   - **Timeframe**: Candle interval (default: 1 minute)
   - **Oversold Threshold**: Buy when RSI falls below this (default: 30)
   - **Overbought Threshold**: Sell when RSI rises above this (default: 70)
   - **Risk Parameters**: Max position size, stop loss, take profit

4. Click "Save Strategy"
5. Click "Start" to begin live trading (paper trading by default)

### Monitoring Strategies

Click on any strategy to view:
- **Current Status**: Running/Stopped
- **Positions**: Open positions with real-time P&L
- **Trade History**: All executed trades
- **Performance Metrics**: Win rate, total P&L, ROI
- **RSI Chart**: Visual representation of RSI indicator and signals

### API Usage Examples

#### Using the Tradier API Client

```elixir
# Get account balances
{:ok, balances} = SofiTrader.Tradier.Accounts.get_balances("your_account_id")

# Get real-time quotes
{:ok, quotes} = SofiTrader.Tradier.MarketData.get_quotes(["AAPL", "MSFT", "GOOGL"])

# Get historical candles
{:ok, candles} = SofiTrader.Tradier.MarketData.get_history(
  "AAPL",
  interval: "1min",
  start: ~D[2024-01-01],
  end: ~D[2024-01-31]
)

# Place an order
order_params = %{
  class: "equity",
  symbol: "AAPL",
  side: "buy",
  quantity: 100,
  type: "market",
  duration: "day"
}
{:ok, order} = SofiTrader.Tradier.Trading.place_order("your_account_id", order_params)
```

#### Accessing Cached Market Data

```elixir
# Get price history from ETS (lock-free, instant access)
price_history = SofiTrader.MarketData.PriceStore.get_price_history("AAPL")

# Get latest candles
candles = SofiTrader.MarketData.PriceStore.get_candles("AAPL", "1min")

# Get latest quote
{:ok, quote} = SofiTrader.MarketData.PriceStore.get_quote("AAPL")

# Subscribe to real-time quote updates
SofiTrader.MarketData.QuoteCache.subscribe("AAPL")

# Receive updates via PubSub message
receive do
  {:quote_update, symbol, quote_data} ->
    IO.inspect(quote_data, label: "New quote for #{symbol}")
end
```

#### Implementing a Custom Strategy

```elixir
defmodule MyCustomStrategy do
  @moduledoc """
  Custom trading strategy implementation.
  """

  @doc """
  Analyze market data and return trading signal.

  Returns:
  - :buy - Open long position
  - :sell - Close position
  - :hold - No action
  """
  def analyze(candle, price_history, config) do
    # Your strategy logic here
    if should_buy?(candle, price_history, config) do
      :buy
    else
      :hold
    end
  end

  defp should_buy?(candle, price_history, config) do
    # Implement your logic
    # Example: Buy if price drops below moving average
    current_price = candle.close
    ma = calculate_moving_average(price_history, config.ma_period)
    current_price < ma
  end
end
```

## Configuration

### Environment Variables

- `TRADIER_ACCESS_TOKEN`: Your Tradier API access token (required)
- `TRADIER_SANDBOX`: Set to "true" for paper trading, "false" for live trading
- `TRADIER_ACCOUNT_ID`: Your Tradier account ID
- `DATABASE_URL`: PostgreSQL connection URL (production)

### Application Configuration

Key configuration in `config/config.exs`:

```elixir
config :sofi_trader, :tradier,
  base_url: "https://api.tradier.com/v1",
  sandbox_url: "https://sandbox.tradier.com/v1",
  stream_url: "https://stream.tradier.com/v1",
  sandbox: System.get_env("TRADIER_SANDBOX", "true") == "true"
```

## Architecture Highlights

### OTP Supervision Tree

```
SofiTrader.Supervisor (one_for_one)
├── SofiTrader.Repo
├── Phoenix.PubSub
├── Registry (StrategyRegistry)
├── SofiTrader.Strategies.Supervisor (DynamicSupervisor)
│   └── Strategy.Runner processes (one per active strategy)
├── Registry (MarketDataRegistry)
├── SofiTrader.MarketData.PriceStore (ETS cache)
├── SofiTrader.MarketData.QuoteCache (quote fetching + PubSub)
├── SofiTrader.MarketData.WebSocketManager (production only)
├── SofiTrader.MarketData.Supervisor (DynamicSupervisor)
│   └── CandleAggregator processes (one per symbol/timeframe)
└── SofiTraderWeb.Endpoint
```

### Data Flow

1. **Market Data Ingestion**:
   - QuoteCache fetches quotes every 10 seconds
   - Stores in ETS via PriceStore
   - Broadcasts to all subscribers via PubSub

2. **Strategy Execution**:
   - CandleAggregator builds candles from quotes
   - Publishes completed candles via PubSub
   - Strategy.Runner receives candles
   - Executes strategy logic
   - Places orders via Tradier API

3. **UI Updates**:
   - LiveView processes subscribe to PubSub
   - Receive real-time updates
   - Push changes to connected browsers

## Development Roadmap

### Completed Features
- ✅ RSI Mean Reversion strategy
- ✅ Phoenix LiveView dashboard
- ✅ Paper trading mode
- ✅ Real-time market data with PubSub
- ✅ ETS-based high-performance caching
- ✅ Strategy management UI
- ✅ Position and trade tracking

### In Progress
- 🔄 WebSocket fault tolerance improvements
- 🔄 GenStage backpressure handling
- 🔄 LiveView performance optimizations

### Planned Features
- [ ] Additional strategies (MACD, Bollinger Bands, Moving Average Crossover)
- [ ] Backtesting framework with historical data
- [ ] Advanced risk management (max drawdown, portfolio heat)
- [ ] Multi-account support
- [ ] Advanced order types (OCO, bracket orders, trailing stops)
- [ ] Performance analytics and reporting
- [ ] Strategy optimization tools
- [ ] News sentiment analysis integration
- [ ] AI/ML decision engine

## Testing

Run the test suite:
```bash
mix test
```

Run with coverage:
```bash
mix test --cover
```

## Production Deployment

1. Set production environment variables
2. Update `config/runtime.exs` with production settings
3. Ensure `TRADIER_SANDBOX=false` for live trading
4. Build release:
```bash
MIX_ENV=prod mix release
```

See [Phoenix deployment guides](https://hexdocs.pm/phoenix/deployment.html) for more details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

[Your License Here]

## Resources

- [Tradier API Documentation](https://documentation.tradier.com/)
- [Phoenix Framework](https://www.phoenixframework.org/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Elixir Documentation](https://elixir-lang.org/docs.html)
- [OTP Design Principles](https://www.erlang.org/doc/design_principles/users_guide.html)

## Disclaimer

**IMPORTANT**: This software is for educational purposes only. Trading stocks and options involves substantial risk of loss.

- Always test thoroughly with sandbox/paper trading before using real money
- Past performance does not guarantee future results
- You are solely responsible for any trading decisions and their outcomes
- The authors assume no liability for any losses incurred

Use at your own risk.
