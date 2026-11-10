// SCHQ Prop Rule Guard for NinjaTrader 8
// Shows, on the chart, how much room a futures prop account has left before it breaks the
// daily loss limit or the trailing drawdown, how far the profit target is, how many contracts
// are open against the limit, and what happens if every open stop is hit.
// It reads the account only. It never places, changes or cancels orders.
//
// SignalCheckerHQ · https://signalcheckerhq.org
// License: Mozilla Public License 2.0

#region Using declarations
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Media;
using System.Xml.Serialization;
using NinjaTrader.Cbi;
using NinjaTrader.Gui;
using NinjaTrader.Gui.Chart;
using NinjaTrader.Gui.Tools;
using NinjaTrader.NinjaScript;
using NinjaTrader.NinjaScript.DrawingTools;
#endregion

// Declared outside the namespace so NinjaTrader's generated code (strategies, Market Analyzer)
// can see it; an enum inside the Indicators namespace breaks the compile there.
public enum SCHQTrailMode
{
    Static,          // start balance minus the limit
    IntradayTrailing,// highest net liquidation (open profit included) minus the limit
    EndOfDayTrailing // highest end-of-day balance minus the limit
}

namespace NinjaTrader.NinjaScript.Indicators
{
    public class SCHQPropRuleGuard : Indicator
    {
        private Account account;
        private double peakNetLiq;
        private double peakEodBalance;
        private string lastEodDay = "";
        private string stateFile;
        private int lastDailyState = -1, lastDDState = -1, lastRiskState = -1, lastContractState = -1;
        private bool targetNotified;
        private DateTime lastDraw = DateTime.MinValue;
        private static readonly Brush PanelBrush = MakePanelBrush();

        private static Brush MakePanelBrush()
        {
            var b = new SolidColorBrush(Color.FromRgb(16, 20, 28));
            b.Freeze();   // brushes used from NinjaScript must be frozen
            return b;
        }

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Description = "Daily loss, trailing drawdown, profit target and contract limit of a futures prop account on the chart, with a warning before a rule breaks. Reads the account only.";
                Name = "SCHQ Prop Rule Guard";
                Calculate = Calculate.OnPriceChange;
                IsOverlay = true;
                DisplayInDataBox = false;
                DrawOnPricePanel = true;
                PaintPriceMarkers = false;
                IsSuspendedWhileInactive = false;

                AccountName = "";   // empty = find the account automatically
                StartBalance = 50000;
                DailyLossLimit = 1000;
                MaxDrawdown = 2000;
                TrailMode = SCHQTrailMode.IntradayTrailing;
                TrailStopsAtStart = true;
                ProfitTarget = 3000;
                MaxContracts = 5;
                WarnPercent = 80;
                PopupAlerts = true;
                PanelPosition = TextPosition.TopLeft;
            }
            else if (State == State.DataLoaded)
            {
                account = FindAccount();

                string dir = Path.Combine(NinjaTrader.Core.Globals.UserDataDir, "SCHQ");
                Directory.CreateDirectory(dir);
                stateFile = Path.Combine(dir, "PropRuleGuard_" + Safe(account != null ? account.Name : AccountName) + ".txt");
                LoadState();
            }
            else if (State == State.Terminated)
            {
                SaveState();
            }
        }

        protected override void OnBarUpdate()
        {
            if (State != State.Realtime)
                return;
            // redraw at most twice a second
            if ((DateTime.Now - lastDraw).TotalMilliseconds < 500)
                return;
            lastDraw = DateTime.Now;
            UpdatePanel();
        }

        private void UpdatePanel()
        {
            if (account == null)
                account = FindAccount();   // accounts can connect after the chart loads
            if (account == null)
            {
                Draw.TextFixed(this, "SCHQ_PRG", "Prop Rule Guard: account \"" + AccountName + "\" not found. Check the Account name input.",
                    PanelPosition, Brushes.Tomato, new SimpleFont("Segoe UI", 11), Brushes.Transparent, Brushes.Black, 85);
                return;
            }

            // NinjaTrader's own account values
            double cash       = account.Get(AccountItem.CashValue, Currency.UsDollar);
            double realized   = account.Get(AccountItem.RealizedProfitLoss, Currency.UsDollar);   // since NinjaTrader's session start
            double unrealized = account.Get(AccountItem.UnrealizedProfitLoss, Currency.UsDollar);
            double netLiq     = cash + unrealized;

            // trailing peaks
            if (netLiq > peakNetLiq) peakNetLiq = netLiq;
            string today = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (lastEodDay != today)
            {
                // the first update of a new day: the cash balance now is yesterday's closing balance
                if (cash > peakEodBalance) peakEodBalance = cash;
                lastEodDay = today;
                SaveState();
            }

            // daily loss: today's closed + open result against the limit
            double dayPnl    = realized + unrealized;
            double dailyUsed = Math.Max(0, -dayPnl);
            double dailyLeft = DailyLossLimit - dailyUsed;

            // drawdown floor
            double floor = StartBalance - MaxDrawdown;
            if (TrailMode == SCHQTrailMode.IntradayTrailing)
                floor = Math.Max(StartBalance, peakNetLiq) - MaxDrawdown;
            else if (TrailMode == SCHQTrailMode.EndOfDayTrailing)
                floor = Math.Max(StartBalance, peakEodBalance) - MaxDrawdown;
            if (TrailMode != SCHQTrailMode.Static && TrailStopsAtStart)
                floor = Math.Min(floor, StartBalance);
            double ddLeft = netLiq - floor;
            double ddUsed = Math.Max(0, MaxDrawdown - ddLeft);

            double roomLeft = Math.Min(dailyLeft, ddLeft);

            // open contracts and risk to the working stops
            int contracts = 0;
            int noStop = 0;
            double openRisk = 0;
            lock (account.Positions)
            {
                foreach (Position p in account.Positions)
                {
                    if (p.MarketPosition == MarketPosition.Flat) continue;
                    contracts += p.Quantity;
                    double stop = WorkingStopPrice(p);
                    if (double.IsNaN(stop)) { noStop++; continue; }
                    double last = p.Instrument.MarketData != null && p.Instrument.MarketData.Last != null
                        ? p.Instrument.MarketData.Last.Price : p.AveragePrice;
                    double pointValue = p.Instrument.MasterInstrument.PointValue;
                    double move = p.MarketPosition == MarketPosition.Long ? last - stop : stop - last;
                    if (move > 0) openRisk += move * pointValue * p.Quantity;
                }
            }

            int dailyState    = StateFor(dailyUsed, DailyLossLimit, dailyLeft);
            int ddState       = StateFor(ddUsed, MaxDrawdown, ddLeft);
            int riskState     = (noStop > 0 || openRisk >= roomLeft) ? 2 : (openRisk >= roomLeft * WarnPercent / 100.0 ? 1 : 0);
            int contractState = MaxContracts > 0 && contracts > MaxContracts ? 2 : (MaxContracts > 0 && contracts == MaxContracts ? 1 : 0);

            var sb = new StringBuilder();
            sb.AppendLine("Prop Rule Guard · SignalCheckerHQ   (" + account.Name + ")");
            sb.AppendLine(string.Format("Start {0}   Net liq {1}   Today {2}", M(StartBalance), M(netLiq), M(dayPnl)));
            sb.AppendLine(string.Format("{0} Daily loss: {1} of {2} used · {3} left", Mark(dailyState), M(dailyUsed), M(DailyLossLimit), M(Math.Max(0, dailyLeft))));
            sb.AppendLine(string.Format("{0} Drawdown: floor {1} ({2}) · {3} left", Mark(ddState), M(floor), ModeText(), M(Math.Max(0, ddLeft))));
            sb.AppendLine(string.Format("   Room before a rule breaks: {0}", M(Math.Max(0, roomLeft))));
            if (noStop > 0)
                sb.AppendLine(string.Format("{0} Open risk: {1} position(s) WITHOUT a working stop", Mark(2), noStop));
            else
                sb.AppendLine(string.Format("{0} Open risk if every stop fills: {1}", Mark(riskState), M(openRisk)));
            if (MaxContracts > 0)
                sb.AppendLine(string.Format("{0} Contracts open: {1} of {2}", Mark(contractState), contracts, MaxContracts));
            if (ProfitTarget > 0)
            {
                double toGo = StartBalance + ProfitTarget - cash;
                sb.AppendLine(toGo <= 0
                    ? "Profit target " + M(ProfitTarget) + " reached (closed balance)"
                    : string.Format("Profit target {0}: {1} to go", M(ProfitTarget), M(toGo)));
                if (toGo <= 0 && !targetNotified) { targetNotified = true; Send("profit target reached on closed balance."); }
            }
            sb.AppendLine("Check these rules against your firm's current terms. Reads the account only. Not financial advice.");

            int worst = Math.Max(Math.Max(dailyState, ddState), Math.Max(riskState, contractState));
            Brush text = worst == 2 ? Brushes.Tomato : worst == 1 ? Brushes.Orange : Brushes.Gainsboro;
            Draw.TextFixed(this, "SCHQ_PRG", sb.ToString(), PanelPosition, text, new SimpleFont("Segoe UI", 11),
                Brushes.DimGray, PanelBrush, 90);

            Notify(ref lastDailyState, dailyState, "Daily loss: " + M(Math.Max(0, dailyLeft)) + " left today");
            Notify(ref lastDDState, ddState, "Drawdown: " + M(Math.Max(0, ddLeft)) + " left above the floor " + M(floor));
            Notify(ref lastRiskState, riskState, noStop > 0 ? noStop + " position(s) have no working stop"
                                                            : "if every stop fills, " + M(openRisk) + " would be lost (room " + M(roomLeft) + ")");
            Notify(ref lastContractState, contractState, "contracts open " + contracts + " of " + MaxContracts);
        }

        // the stop price of the account's working stop orders for this instrument, on the side that closes the position
        private double WorkingStopPrice(Position p)
        {
            double best = double.NaN;
            lock (account.Orders)
            {
                foreach (Order o in account.Orders)
                {
                    if (o.Instrument != p.Instrument) continue;
                    if (o.OrderState != OrderState.Working && o.OrderState != OrderState.Accepted) continue;
                    if (o.OrderType != OrderType.StopMarket && o.OrderType != OrderType.StopLimit) continue;
                    bool closes = (p.MarketPosition == MarketPosition.Long && (o.OrderAction == OrderAction.Sell))
                               || (p.MarketPosition == MarketPosition.Short && (o.OrderAction == OrderAction.BuyToCover || o.OrderAction == OrderAction.Buy));
                    if (!closes) continue;
                    // the farthest stop is the worst case
                    if (double.IsNaN(best)) best = o.StopPrice;
                    else best = p.MarketPosition == MarketPosition.Long ? Math.Min(best, o.StopPrice) : Math.Max(best, o.StopPrice);
                }
            }
            return best;
        }

        private int StateFor(double used, double limit, double left)
        {
            if (left <= 0) return 2;
            if (limit > 0 && used >= limit * WarnPercent / 100.0) return 1;
            return 0;
        }

        private void Notify(ref int last, int now, string detail)
        {
            if (now == last) return;
            if (last != -1 && now > last)
                Send((now == 2 ? "BREACH: " : "WARNING: ") + detail + ".");
            last = now;
        }

        private void Send(string msg)
        {
            string full = "Prop Rule Guard (" + (account != null ? account.Name : AccountName) + "): " + msg;
            Print(full);
            if (PopupAlerts)
                Alert("SCHQ_PRG_" + Guid.NewGuid().ToString("N"), Priority.High, full, NinjaTrader.Core.Globals.InstallDir + @"\sounds\Alert2.wav", 0, Brushes.Black, Brushes.Orange);
        }

        private string ModeText()
        {
            if (TrailMode == SCHQTrailMode.Static) return "static";
            string s = TrailMode == SCHQTrailMode.IntradayTrailing ? "trails intraday high" : "trails end-of-day high";
            return TrailStopsAtStart ? s + ", stops at start" : s;
        }

        // The account to read: the name typed in the settings, or, if that is empty, the first trading
        // account NinjaTrader has (a demo/sim or prop account; Backtest and Playback are skipped, Sim101 last).
        private Account FindAccount()
        {
            lock (Account.All)
            {
                if (!string.IsNullOrWhiteSpace(AccountName))
                    return Account.All.FirstOrDefault(a => a.Name == AccountName.Trim());
                var list = Account.All.Where(a => a.Name != "Backtest" && !a.Name.StartsWith("Playback")).ToList();
                return list.FirstOrDefault(a => a.Name != "Sim101") ?? list.FirstOrDefault();
            }
        }

        private static string Mark(int state) { return state == 2 ? "✖" : state == 1 ? "!" : "✓"; }
        private static string M(double v) { return v.ToString("$#,##0.00;-$#,##0.00", CultureInfo.InvariantCulture); }
        private static string Safe(string s) { foreach (char c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '_'); return s; }

        // peaks survive a restart of NinjaTrader
        private void LoadState()
        {
            peakNetLiq = StartBalance;
            peakEodBalance = StartBalance;
            try
            {
                if (!File.Exists(stateFile)) return;
                string[] parts = File.ReadAllText(stateFile).Split(';');
                if (parts.Length >= 3)
                {
                    peakNetLiq = Math.Max(StartBalance, double.Parse(parts[0], CultureInfo.InvariantCulture));
                    peakEodBalance = Math.Max(StartBalance, double.Parse(parts[1], CultureInfo.InvariantCulture));
                    lastEodDay = parts[2];
                }
            }
            catch (Exception e) { Print("Prop Rule Guard: could not read saved peaks (" + e.Message + "); starting from the start balance."); }
        }

        private void SaveState()
        {
            try
            {
                if (string.IsNullOrEmpty(stateFile)) return;
                File.WriteAllText(stateFile, string.Join(";",
                    peakNetLiq.ToString(CultureInfo.InvariantCulture),
                    peakEodBalance.ToString(CultureInfo.InvariantCulture),
                    lastEodDay));
            }
            catch (Exception e) { Print("Prop Rule Guard: could not save peaks (" + e.Message + ")."); }
        }

        #region Properties
        [NinjaScriptProperty]
        [Display(Name = "Account name", Order = 1, GroupName = "1. Account", Description = "Leave empty to use your account automatically, or type it exactly as shown in NinjaTrader's Accounts tab (e.g. a DEMO..., Sim101 or prop account name).")]
        public string AccountName { get; set; }

        [NinjaScriptProperty]
        [Range(1, double.MaxValue)]
        [Display(Name = "Starting balance ($)", Order = 2, GroupName = "1. Account")]
        public double StartBalance { get; set; }

        [NinjaScriptProperty]
        [Range(0, double.MaxValue)]
        [Display(Name = "Daily loss limit ($, 0 = none)", Order = 1, GroupName = "2. Rules")]
        public double DailyLossLimit { get; set; }

        [NinjaScriptProperty]
        [Range(1, double.MaxValue)]
        [Display(Name = "Max drawdown ($)", Order = 2, GroupName = "2. Rules")]
        public double MaxDrawdown { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Drawdown type", Order = 3, GroupName = "2. Rules")]
        public SCHQTrailMode TrailMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Trailing stops at the starting balance", Order = 4, GroupName = "2. Rules")]
        public bool TrailStopsAtStart { get; set; }

        [NinjaScriptProperty]
        [Range(0, double.MaxValue)]
        [Display(Name = "Profit target ($, 0 = none)", Order = 5, GroupName = "2. Rules")]
        public double ProfitTarget { get; set; }

        [NinjaScriptProperty]
        [Range(0, int.MaxValue)]
        [Display(Name = "Max contracts (0 = none)", Order = 6, GroupName = "2. Rules")]
        public int MaxContracts { get; set; }

        [NinjaScriptProperty]
        [Range(1, 99)]
        [Display(Name = "Warn at % of a limit used", Order = 1, GroupName = "3. Warnings")]
        public double WarnPercent { get; set; }

        [Display(Name = "Pop-up alerts", Order = 2, GroupName = "3. Warnings")]
        public bool PopupAlerts { get; set; }

        [Display(Name = "Panel position", Order = 1, GroupName = "4. Panel")]
        public TextPosition PanelPosition { get; set; }
        #endregion
    }
}
