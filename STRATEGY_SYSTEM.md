# Automated Trading Strategy System

## Overview

The crown jewel of SofiTrader - an automated trading strategy system with comprehensive risk management, real-time monitoring, and configurable trading strategies.

## Architecture

### 1. Strategy System

**Initial Strategy: RSI Mean Reversion**
- **Simple and Effective**: Proven strategy for beginners
- **Buy Signal**: RSI < 30 (oversold conditions)
- **Sell Signal**: RSI > 70 (overbought) OR stop-loss/take-profit triggered
- **Implementation**: Each strategy instance runs as a supervised GenServer
- **Extensible**: Strategy behavior pattern allows easy addition of new strategies

**Alternative Strategies** (Future):
- Moving Average Crossover (SMA 9/21)
- MACD + RSI Combination
- Bollinger Bands Mean Reversion

### 2. Risk Management Controls

Essential controls to protect capital and prevent catastrophic losses:

| Control | Purpose | Default Value |
|---------|---------|---------------|
| **Position Size %** | Percentage of buying power per trade | 10% |
| **Max Concurrent Positions** | Cap total number of open positions | 3 |
| **Max Positions Per Symbol** | Prevent concentration risk | 1 |
| **Stop Loss %** | Auto-exit if position drops X% | 2% |
| **Take Profit %** | Auto-exit if position gains X% | 5% |
| **Max Daily Loss %** | Circuit breaker to stop all trading | 3% of portfolio |
| **Cooldown Period** | Prevent overtrading same symbol | 15 minutes |

### 3. Database Schema

```elixir
# strategies table
create table(:strategies) do
  add :name, :string, null: false
  add :symbol, :string, null: false
  add :type, :string, null: false  # "rsi_mean_reversion", "ma_crossover", etc.

  # Strategy-specific configuration
  add :config, :map, default: %{}
  # Example for RSI: %{
  #   rsi_period: 14,
  #   oversold_threshold: 30,
  #   overbought_threshold: 70,
  #   timeframe: "5min"  # or "1hour", "daily"
  # }

  # Risk management parameters
  add :risk_params, :map, default: %{}
  # Example: %{
  #   position_size_pct: 10.0,
  #   stop_loss_pct: 2.0,
  #   take_profit_pct: 5.0,
  #   max_positions: 3,
  #   max_positions_per_symbol: 1,
  #   max_daily_loss_pct: 3.0,
  #   cooldown_minutes: 15
  # }

  add :status, :string, default: "stopped"  # active, paused, stopped

  # Performance statistics
  add :stats, :map, default: %{}
  # Example: %{
  #   total_trades: 0,
  #   winning_trades: 0,
  #   losing_trades: 0,
  #   win_rate: 0.0,
  #   total_pnl: 0.0,
  #   total_pnl_pct: 0.0,
  #   largest_win: 0.0,
  #   largest_loss: 0.0,
  #   current_streak: 0
  # }

  timestamps()
end

# strategy_positions table
create table(:strategy_positions) do
  add :strategy_id, references(:strategies, on_delete: :delete_all), null: false
  add :symbol, :string, null: false
  add :side, :string, null: false  # "buy" or "sell"
  add :quantity, :integer, null: false

  add :entry_price, :decimal, precision: 10, scale: 2
  add :current_price, :decimal, precision: 10, scale: 2
  add :stop_loss_price, :decimal, precision: 10, scale: 2
  add :take_profit_price, :decimal, precision: 10, scale: 2

  add :pnl, :decimal, precision: 10, scale: 2, default: 0.0
  add :pnl_percent, :decimal, precision: 10, scale: 2, default: 0.0

  add :status, :string, default: "open"  # open, closed
  add :close_reason, :string  # "take_profit", "stop_loss", "manual", "strategy_signal"

  add :opened_at, :utc_datetime
  add :closed_at, :utc_datetime

  timestamps()
end

# strategy_trades table (individual order executions)
create table(:strategy_trades) do
  add :strategy_id, references(:strategies, on_delete: :delete_all), null: false
  add :position_id, references(:strategy_positions, on_delete: :nilify_all)
  add :order_id, :string  # Tradier order ID

  add :symbol, :string, null: false
  add :side, :string, null: false  # "buy" or "sell"
  add :quantity, :integer, null: false
  add :price, :decimal, precision: 10, scale: 2
  add :fees, :decimal, precision: 10, scale: 2, default: 0.0

  # For closing trades
  add :pnl, :decimal, precision: 10, scale: 2
  add :pnl_percent, :decimal, precision: 10, scale: 2

  add :executed_at, :utc_datetime

  timestamps()
end

# Create indexes
create index(:strategy_positions, [:strategy_id])
create index(:strategy_positions, [:symbol])
create index(:strategy_positions, [:status])
create index(:strategy_trades, [:strategy_id])
create index(:strategy_trades, [:position_id])
create index(:strategy_trades, [:symbol])
```

### 4. UI Views

#### Strategy Manager (`/strategies`)
- **List View**: Shows all configured strategies
  - Strategy name, symbol, type, status (active/paused/stopped)
  - Quick stats: Win rate, total P&L, # of trades
  - Action buttons: Start, Pause, Stop, Edit, Delete
- **Create/Edit Form**: Configure new strategy
  - Select symbol
  - Choose strategy type (dropdown)
  - Configure strategy parameters (dynamic based on type)
  - Set risk management controls
  - Name the strategy

#### Live Monitor (`/strategies/:id/monitor`)
Real-time monitoring dashboard with:

**Active Positions Panel**
- Table showing all open positions
- Columns: Symbol, Entry Price, Current Price, Quantity, P&L, P&L%, Stop Loss, Take Profit, Duration
- Color-coded: Green for profit, Red for loss
- Live updates every second

**Recent Trades Panel**
- Table of recent executions (last 50)
- Columns: Time, Symbol, Side, Quantity, Price, P&L, Status
- Filterable by date range

**Performance Charts**
- P&L over time (line chart)
- Win/Loss distribution (bar chart)
- Daily performance calendar heatmap

**Indicators Panel**
- Current RSI value with gauge
- Recent price action candlestick chart
- Entry/exit zones visualization

**Risk Metrics Dashboard**
- Current buying power usage
- Daily P&L vs. max daily loss limit
- Number of positions vs. max positions
- Risk utilization percentage

**Strategy Controls**
- Pause/Resume button
- Emergency stop (close all positions)
- Edit risk parameters (live)

### 5. Technical Implementation

#### Strategy Runner (GenServer)
```elixir
defmodule SofiTrader.Strategies.Runner do
  use GenServer

  # Subscribes to:
  # - Market data stream for the symbol
  # - Candle aggregation for technical indicators

  # On each new candle:
  # 1. Calculate indicators (RSI, MA, etc.)
  # 2. Check entry conditions
  # 3. Check exit conditions for open positions
  # 4. Execute trades via Tradier API
  # 5. Update position tracking
  # 6. Enforce risk limits

  # State includes:
  # - Strategy config
  # - Current positions
  # - Indicator history
  # - Risk tracking (daily loss, cooldowns)
end
```

#### Technical Indicator Calculator
```elixir
defmodule SofiTrader.Indicators do
  # RSI calculation
  def calculate_rsi(prices, period \\ 14)

  # Moving averages
  def calculate_sma(prices, period)
  def calculate_ema(prices, period)

  # MACD
  def calculate_macd(prices)

  # Bollinger Bands
  def calculate_bollinger_bands(prices, period, std_dev)
end
```

#### Risk Manager
```elixir
defmodule SofiTrader.RiskManager do
  # Check if trade is allowed based on risk parameters
  def can_open_position?(strategy, symbol, size)

  # Calculate position size based on risk %
  def calculate_position_size(strategy, current_price)

  # Check stop loss / take profit conditions
  def check_exit_conditions(position, current_price)

  # Monitor daily loss limit
  def check_daily_loss_limit(strategy)
end
```

## Implementation Plan

### Phase 1: Foundation
1. Create database migrations
2. Create Ecto schemas (Strategy, StrategyPosition, StrategyTrade)
3. Build technical indicator calculator module
4. Build risk manager module

### Phase 2: Strategy Engine
1. Implement RSI Mean Reversion strategy
2. Create Strategy Runner GenServer
3. Integrate with market data stream
4. Integrate with Tradier Trading API
5. Add position tracking and management

### Phase 3: UI
1. Build Strategy Manager LiveView
2. Build Live Monitor LiveView
3. Add real-time updates via Phoenix PubSub
4. Create performance charts
5. Add strategy creation/edit forms

### Phase 4: Testing & Safety
1. Paper trading mode (simulate orders)
2. Backtesting against historical data
3. Comprehensive error handling
4. Automated tests for risk limits
5. Alert system for critical events

## Configuration Questions

Before implementation, decide on:

1. **Timeframe**:
   - 5-minute candles for intraday trading?
   - 1-hour/daily for swing trading?
   - Make it configurable per strategy?

2. **Initial Strategy**:
   - Start with RSI Mean Reversion?
   - Or prefer Moving Average Crossover (SMA 9/21)?

3. **Default Risk Parameters**:
   - 10% position size reasonable?
   - 2% stop loss, 5% take profit good defaults?

4. **Auto-restart**:
   - Should strategies auto-restart after server reboot if they were active?
   - Or require manual restart for safety?

5. **Paper Trading**:
   - Build paper trading mode first before live trading?

## Safety Considerations

- **Sandbox First**: Test extensively in Tradier sandbox before production
- **Paper Trading Mode**: Simulate trades without real money
- **Kill Switch**: Easy way to stop all strategies immediately
- **Audit Log**: Record all decisions and trades for analysis
- **Alerts**: Email/SMS notifications for significant events (large loss, system errors)
- **Position Limits**: Hard caps to prevent runaway trading
- **API Rate Limits**: Respect Tradier API limits (120 req/min)

## Future Enhancements

- Multiple strategy types (MA crossover, MACD, Bollinger Bands)
- Strategy optimizer (find best parameters via backtesting)
- Portfolio-level risk management (correlation, diversification)
- News sentiment integration
- Machine learning signal generation
- Strategy marketplace (share/import strategies)
- Mobile app for monitoring
- Advanced charting with TradingView integration
