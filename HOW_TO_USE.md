# How to use Prop Rule Guard and Consistency Rule Tracker

Both indicators only read your account. They never open, change or close trades. Set them up once per account, then glance at the panel before every trade.

## 1. Find your firm's numbers first (5 minutes)

Open your prop firm's rules page and write down:

| What | Example | Where it goes |
|---|---|---|
| Account size | 50,000 | Starting balance |
| Daily loss limit | 1,000 or 2% | Daily loss limit |
| What the daily limit counts from | balance at the day's start, or the higher of balance and equity | "Daily loss is measured from" (MT5) |
| When the trading day resets | 17:00 New York, or 00:00 server time | Hour the trading day starts |
| Max drawdown | 2,000 or 4% | Max drawdown |
| Drawdown type | static, intraday trailing, end-of-day trailing | Drawdown type |
| Does trailing stop at the start balance? | yes / no | Trailing stops at start |
| Profit target | 3,000 or 6% | Profit target |
| Consistency rule | best day ≤ 40% of total profit (or of the target) | Rule % and "of total profit / of the target" |
| Max contracts (futures) | 5 | Max contracts (NinjaTrader) |

If the rules page is unclear, ask the firm's support and keep their answer. Firms word these rules differently, and the panel is only as right as these inputs.

## 2. Install

**NinjaTrader 8:** Tools > Import > NinjaScript Add-On > `ninjatrader8/SCHQ_PropTools_NT8.zip`. Open a chart, right-click > Indicators, add **SCHQ Prop Rule Guard** and/or **SCHQ Consistency Tracker**. Leave "Account name" empty: the indicator finds your trading account (Sim101 is used last).

**MetaTrader 5:** File > Open Data Folder > MQL5 > Indicators, copy the two `.mq5` files there, open them in MetaEditor and press F7. In MT5, drag the indicator from the Navigator onto any chart of the account. One chart is enough: the panel shows the whole account, not one symbol.

## 3. Set the inputs

Type the numbers from step 1.
- **MT5** takes the limits as **% of the starting balance** (2% of 50,000 = 2). The new day starts at a **server hour** (see the time in Market Watch). Leave the starting balance at 0 to use the balance at the moment you attach the indicator, or type the real start balance if the account already has trades.
- **NinjaTrader** takes the limits in **dollars**. The new day starts at an hour on **this PC's clock** (18 = the 6pm New York futures session, if the PC is on New York time).

Consistency Rule Tracker: in MT5 set the start date to the first day of the evaluation (or of the payout period). In NinjaTrader type earlier days' results in "Earlier days' results" (e.g. 1200, -300, 450); it records every day from the moment you add it.

## 4. Read the panel

**Prop Rule Guard**
- **Room before a rule breaks:** how much more you can lose today before the tighter of the two limits (daily loss or max drawdown) breaks. This is the number to watch.
- **Open risk if every stop is hit:** what the account loses if all your open stops fill. If this is bigger than the room, one bad move breaks the rule. A position without a stop is flagged.
- **Profit target:** how much is left to reach it, on closed balance.
- Colours: green = fine, orange = warning (by default at 80% of a limit), red = breach.

**Consistency Rule Tracker**
- **Best day vs total:** your biggest day as % of total profit (or of the target).
- **Today's cap / room:** the most today can make and still keep the rule. If you are near the cap, closing more profit today can break consistency.
- **If broken:** how much more total profit you need before the rule is OK again.
- **Profitable days:** counted against the number your firm requires.

## 5. A simple routine

1. Before the first trade: check the room and today's cap.
2. Before each trade: is the trade's stop smaller than the room left? If not, trade smaller or skip.
3. After each trade: look at open risk and today's room again.
4. End of day: note the closed result; the trackers do the rest.

Pop-up alerts are on by default. In MT5 you can also turn on push alerts to the MetaTrader phone app.

## 6. Limits

- Equity at the start of the day is only known if the terminal or NinjaTrader was running at that time.
- The panel can't see trades on another platform or another computer.
- Firms change rules. Re-check them when a new evaluation starts.
- Not financial advice. The indicators help you see the rules; they don't make trades better.

Questions or a bug? Open an issue in this repository.
