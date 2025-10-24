# SofiTrader

A modular, extensible automated trading platform built with Elixir and Phoenix, integrating with the Tradier API for real-time market data and trade execution.

## Features

- **Tradier API Integration**: Full REST API client for account management, market data, and trading operations
- **Real-time Market Data**: WebSocket-based streaming for live quotes, trades, and market events
- **Candlestick Aggregation**: Real-time OHLC candle generation from tick data
- **Modular Strategy Framework**: Easy-to-extend strategy behaviour for implementing trading algorithms
- **Position Management**: Comprehensive position tracking with P&L calculation
- **Phoenix Web UI**: Future-ready web interface for monitoring and control
- **Sandbox Support**: Test your strategies safely with Tradier's sandbox environment

## Project Structure

```
lib/sofi_trader/
├── tradier/                    # Tradier API client modules
│   ├── client.ex              # Base HTTP client
│   ├── accounts.ex            # Account operations
│   ├── market_data.ex         # Market data operations
│   ├── trading.ex             # Order placement and management
│   └── websocket.ex           # WebSocket client for streaming
├── market_data/               # Market data processing
│   ├── stream.ex              # Market data stream manager
│   └── candles.ex             # Candlestick aggregator
├── trading/                   # Trading logic
│   ├── strategy.ex            # Strategy behaviour
│   ├── position_manager.ex    # Position management
│   └── strategies/            # Strategy implementations
│       └── simple_moving_average.ex
└── decision_engine/           # Future: AI-powered decision making
```

## Getting Started

### Prerequisites

- Elixir 1.15 or later
- PostgreSQL (for data persistence)
- Tradier API account (get one at https://tradier.com)

### Installation

1. Clone the repository:
```bash
git clone <your-repo-url>
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

5. Set up your Tradier API credentials:
```bash
export TRADIER_ACCESS_TOKEN="your_access_token"
```

Or configure in `config/dev.exs` (not recommended for production):
```elixir
config :sofi_trader, :tradier,
  base_url: "https://api.tradier.com/v1",
  sandbox_url: "https://sandbox.tradier.com/v1",
  stream_url: "https://stream.tradier.com/v1",
  sandbox: true  # Use sandbox for testing
```

6. Start the Phoenix server:
```bash
mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000) from your browser.

## Usage

### Using the Tradier API Client

```elixir
# Get account balances
{:ok, balances} = SofiTrader.Tradier.Accounts.get_balances("your_account_id")

# Get real-time quotes
{:ok, quotes} = SofiTrader.Tradier.MarketData.get_quotes(["AAPL", "MSFT", "GOOGL"])

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

### Streaming Market Data

```elixir
# Start the market data stream
{:ok, stream_pid} = SofiTrader.MarketData.Stream.start_link(name: SofiTrader.MarketData.Stream)

# Subscribe to symbols
SofiTrader.MarketData.Stream.subscribe(stream_pid, ["AAPL", "MSFT"])

# Receive market data messages
receive do
  {:market_data, "trade", symbol, data} ->
    IO.inspect(data, label: "Trade for #{symbol}")
end
```

### Using Candlestick Aggregator

```elixir
# Start candles aggregator with 60-second intervals
{:ok, candles_pid} = SofiTrader.MarketData.Candles.start_link(
  interval: 60,
  symbols: ["AAPL"],
  name: SofiTrader.MarketData.Candles
)

# Subscribe to candle updates
SofiTrader.MarketData.Candles.subscribe(candles_pid, ["AAPL"])

# Receive completed candles
receive do
  {:candle, symbol, candle} ->
    IO.inspect(candle, label: "New candle for #{symbol}")
end
```

### Implementing a Trading Strategy

```elixir
defmodule MyStrategy do
  @behaviour SofiTrader.Trading.Strategy

  @impl true
  def init(config) do
    # Initialize strategy state
    {:ok, %{config: config}}
  end

  @impl true
  def analyze(market_data, state) do
    # Analyze market data and return signal
    signal = :buy  # or :sell, :hold
    {signal, state}
  end

  @impl true
  def position_size(signal, market_data, state) do
    # Calculate position size
    100  # number of shares
  end

  @impl true
  def should_close?(position, market_data, state) do
    # Determine if position should be closed
    false
  end
end
```

### Managing Positions

```elixir
# Start position manager
{:ok, pm_pid} = SofiTrader.Trading.PositionManager.start_link(
  account_id: "your_account_id",
  name: SofiTrader.Trading.PositionManager
)

# Open a position
{:ok, position} = SofiTrader.Trading.PositionManager.open_position(
  pm_pid,
  "AAPL",
  :long,
  100
)

# Get all positions
positions = SofiTrader.Trading.PositionManager.get_positions(pm_pid)

# Close a position
{:ok, order_id} = SofiTrader.Trading.PositionManager.close_position(pm_pid, "AAPL")
```

## Configuration

### Environment Variables

- `TRADIER_ACCESS_TOKEN`: Your Tradier API access token
- `DATABASE_URL`: PostgreSQL connection URL (production)

### Application Configuration

See `config/config.exs`, `config/dev.exs`, and `config/prod.exs` for configuration options.

## Development Roadmap

- [ ] Additional trading strategies (RSI, MACD, Bollinger Bands)
- [ ] AI/ML decision engine integration
- [ ] Backtesting framework
- [ ] Risk management system
- [ ] Phoenix LiveView dashboard
- [ ] Paper trading mode
- [ ] Multi-account support
- [ ] Advanced order types (OCO, bracket orders)
- [ ] News sentiment analysis
- [ ] Performance analytics and reporting

## Testing

Run the test suite:
```bash
mix test
```

## Production Deployment

1. Update `config/runtime.exs` with production settings
2. Set environment variables for secrets
3. Build release:
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
- [Elixir Documentation](https://elixir-lang.org/docs.html)

## Disclaimer

This software is for educational purposes only. Trading stocks and options involves risk. Use at your own risk. Always test thoroughly with sandbox/paper trading before using real money.
