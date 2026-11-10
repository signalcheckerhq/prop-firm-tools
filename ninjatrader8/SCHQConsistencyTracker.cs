// SCHQ Consistency Rule Tracker for NinjaTrader 8
// Many futures prop firms have a "consistency rule": your best single day may not be more than
// X% of your total profit (or of the profit target). This indicator keeps a record of each trading
// day's result for one account and shows on the chart how close you are, how much more you can
// make today without breaking the rule, and how much more total profit you need if it is broken.
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
public enum SCHQConsistencyMode
{
    OfTotalProfit,   // best day vs total profit
    OfProfitTarget   // best day vs the profit target
}

namespace NinjaTrader.NinjaScript.Indicators
{
    public class SCHQConsistencyTracker : Indicator
    {
        private Account account;
        private string dayFile;
        private readonly SortedDictionary<string, double> days = new SortedDictionary<string, double>(StringComparer.Ordinal);
        private int lastState = -1;
        private DateTime lastDraw = DateTime.MinValue;
        private DateTime lastSave = DateTime.MinValue;
        private static readonly Brush PanelBrush = MakePanelBrush();

        private static Brush MakePanelBrush()
        {
            var b = new SolidColorBrush(Color.FromRgb(16, 20, 28));
            b.Freeze();
            return b;
        }

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Description = "Consistency rule of a futures prop account on the chart: best day vs total profit, today's room, profit still needed. Reads the account only.";
                Name = "SCHQ Consistency Tracker";
                Calculate = Calculate.OnPriceChange;
                IsOverlay = true;
                DisplayInDataBox = false;
                DrawOnPricePanel = true;
                PaintPriceMarkers = false;
                IsSuspendedWhileInactive = false;

                AccountName = "";   // empty = find the account automatically
                RulePercent = 40;
                Mode = SCHQConsistencyMode.OfTotalProfit;
                ProfitTarget = 3000;
                EarlierDays = "";
                DayStartHour = 18;
                CountOpenProfit = false;
                MinDayProfit = 0;
                MinDays = 0;
                WarnPercent = 80;
                PopupAlerts = true;
                PanelPosition = TextPosition.TopRight;   // next to Prop Rule Guard (top left)
            }
            else if (State == State.DataLoaded)
            {
                account = FindAccount();
                string dir = Path.Combine(NinjaTrader.Core.Globals.UserDataDir, "SCHQ");
                Directory.CreateDirectory(dir);
                dayFile = Path.Combine(dir, "ConsistencyDays_" + Safe(account != null ? account.Name : AccountName) + ".csv");
                LoadDays();
            }
            else if (State == State.Terminated)
            {
                SaveDays();
            }
        }

        protected override void OnBarUpdate()
        {
            if (State != State.Realtime)
                return;
            if ((DateTime.Now - lastDraw).TotalMilliseconds < 500)
                return;
            lastDraw = DateTime.Now;
            UpdatePanel();
        }

        // the trading day a local time belongs to. An evening start (e.g. 18:00) belongs to the next
        // date, like the CME session; a morning start (e.g. 8:00) keeps the night with the day before.
        private string TradingDay(DateTime t)
        {
            DateTime d = t.AddHours(-DayStartHour).Date;
            if (DayStartHour >= 12) d = d.AddDays(1);
            return d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        }

        private void UpdatePanel()
        {
            if (account == null)
                account = FindAccount();   // accounts can connect after the chart loads
            if (account == null)
            {
                Draw.TextFixed(this, "SCHQ_CRT", "Consistency Tracker: account \"" + AccountName + "\" not found. Check the Account name input.",
                    PanelPosition, Brushes.Tomato, new SimpleFont("Segoe UI", 11), Brushes.Transparent, Brushes.Black, 85);
                return;
            }

            // today's result: NinjaTrader's realized P&L for the current session (+ open P&L if chosen)
            double realized   = account.Get(AccountItem.RealizedProfitLoss, Currency.UsDollar);
            double unrealized = account.Get(AccountItem.UnrealizedProfitLoss, Currency.UsDollar);
            string today = TradingDay(DateTime.Now);
            days[today] = realized;   // the closed result is what gets recorded for the day
            if ((DateTime.Now - lastSave).TotalSeconds > 30) { SaveDays(); lastSave = DateTime.Now; }
            double todayPnl = realized + (CountOpenProfit ? unrealized : 0);

            // earlier days = typed-in days + recorded days before today
            var earlier = ParseEarlierDays();
            earlier.AddRange(days.Where(kv => string.CompareOrdinal(kv.Key, today) < 0).Select(kv => kv.Value));

            double x = RulePercent / 100.0;
            double other = earlier.Sum();
            double total = other + todayPnl;
            double bestOther = earlier.Count > 0 ? Math.Max(0, earlier.Max()) : 0;
            double best = Math.Max(bestOther, Math.Max(0, todayPnl));
            bool bestIsToday = todayPnl > bestOther && todayPnl > 0;

            double allowed, needMore = 0, capToday, share;
            if (Mode == SCHQConsistencyMode.OfProfitTarget)
            {
                allowed = x * ProfitTarget;
                capToday = allowed;
                share = ProfitTarget > 0 ? 100.0 * best / ProfitTarget : 0;
            }
            else
            {
                allowed = total > 0 ? x * total : 0;
                if (best > 0) needMore = Math.Max(0, best / x - total);
                capToday = other > 0 ? x * other / (1 - x) : 0;   // largest T with T <= x * (other + T)
                share = total > 0 ? 100.0 * best / total : (best > 0 ? 100.0 : 0.0);
            }
            double roomToday = capToday - todayPnl;
            bool ruleOk = best <= 0 || best <= allowed + 0.005;
            int state = !ruleOk ? 2 : (capToday > 0 && todayPnl >= capToday * WarnPercent / 100.0 ? 1 : 0);

            int traded = earlier.Count(v => v != 0) + (todayPnl != 0 ? 1 : 0);
            int good = earlier.Count(IsGoodDay) + (IsGoodDay(todayPnl) ? 1 : 0);

            var sb = new StringBuilder();
            sb.AppendLine("Consistency Rule Tracker · SignalCheckerHQ   (" + account.Name + ")");
            sb.AppendLine(Mode == SCHQConsistencyMode.OfProfitTarget
                ? string.Format("Rule: best day ≤ {0:0.#}% of the {1} profit target", RulePercent, M(ProfitTarget))
                : string.Format("Rule: best day ≤ {0:0.#}% of total profit", RulePercent));
            sb.AppendLine(string.Format("Total profit {0} · today {1}{2}", M(total), M(todayPnl), CountOpenProfit ? " (with open P&L)" : ""));
            sb.AppendLine(best > 0
                ? string.Format("{0} Best day {1} ({2}) = {3:0.0}% of {4}", Mark(state), M(best), bestIsToday ? "today" : "earlier day", share,
                    Mode == SCHQConsistencyMode.OfProfitTarget ? "the target" : "total profit")
                : "Best day: no profitable day yet");
            if (Mode == SCHQConsistencyMode.OfTotalProfit && best > 0 && !ruleOk)
                sb.AppendLine(string.Format("✖ Rule broken now: {0} more total profit needed (best day stays {1})", M(needMore), M(best)));
            else
                sb.AppendLine(string.Format("   Allowed best day: {0}", M(allowed)));
            if (capToday > 0)
                sb.AppendLine(roomToday > 0
                    ? string.Format("   Today can make up to {0} more (cap {1})", M(roomToday), M(capToday))
                    : string.Format("! Today is over its cap of {0} by {1}", M(capToday), M(-roomToday)));
            else
                sb.AppendLine("   Today: no room yet (no earlier profit, so any profit today is 100% of the total)");
            sb.AppendLine(MinDays > 0
                ? string.Format("{0} Profitable days{1}: {2} of {3} required", good >= MinDays ? "✓" : "!", MinDayProfit > 0 ? " (≥ " + M(MinDayProfit) + ")" : "", good, MinDays)
                : string.Format("   Days traded {0} · profitable days{1} {2}", traded, MinDayProfit > 0 ? " (≥ " + M(MinDayProfit) + ")" : "", good));
            sb.AppendLine(!ruleOk ? "RULE BROKEN: keep trading small until the total catches up"
                        : state == 1 ? "WARNING: today is close to its cap" : "Consistency rule OK");
            sb.AppendLine(string.Format("Days start at {0}:00 (this PC's time). Recorded days: {1}. Check the rule against your firm's current terms. Not financial advice.", DayStartHour, days.Count));

            Brush text = state == 2 ? Brushes.Tomato : state == 1 ? Brushes.Orange : Brushes.Gainsboro;
            Draw.TextFixed(this, "SCHQ_CRT", sb.ToString(), PanelPosition, text, new SimpleFont("Segoe UI", 11),
                Brushes.DimGray, PanelBrush, 90);

            if (state != lastState)
            {
                if (lastState != -1 && state > lastState)
                    Send(state == 2
                        ? string.Format("rule broken: best day {0} = {1:0.0}%{2}", M(best), share,
                            Mode == SCHQConsistencyMode.OfTotalProfit ? ", " + M(needMore) + " more total profit needed." : " of the target.")
                        : string.Format("today {0} of its {1} cap.", M(todayPnl), M(capToday)));
                lastState = state;
            }
        }

        private bool IsGoodDay(double v) { return v > 0 && v >= MinDayProfit; }

        // "1200, -300, 450" or one per line: results of days before this indicator was added
        private List<double> ParseEarlierDays()
        {
            var list = new List<double>();
            if (string.IsNullOrWhiteSpace(EarlierDays)) return list;
            foreach (string part in EarlierDays.Split(new[] { ',', ';', '\n', '\r', ' ' }, StringSplitOptions.RemoveEmptyEntries))
            {
                double v;
                if (double.TryParse(part.Replace("$", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out v))
                    list.Add(v);
            }
            return list;
        }

        private void Send(string msg)
        {
            string full = "Consistency Tracker (" + (account != null ? account.Name : AccountName) + "): " + msg;
            Print(full);
            if (PopupAlerts)
                Alert("SCHQ_CRT_" + Guid.NewGuid().ToString("N"), Priority.High, full, NinjaTrader.Core.Globals.InstallDir + @"\sounds\Alert2.wav", 0, Brushes.Black, Brushes.Orange);
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

        // one line per trading day: yyyy-MM-dd;result
        private void LoadDays()
        {
            days.Clear();
            try
            {
                if (!File.Exists(dayFile)) return;
                foreach (string line in File.ReadAllLines(dayFile))
                {
                    string[] p = line.Split(';');
                    double v;
                    if (p.Length == 2 && double.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out v))
                        days[p[0]] = v;
                }
            }
            catch (Exception e) { Print("Consistency Tracker: could not read the day file (" + e.Message + ")."); }
        }

        private void SaveDays()
        {
            try
            {
                if (string.IsNullOrEmpty(dayFile)) return;
                File.WriteAllLines(dayFile, days.Select(kv => kv.Key + ";" + kv.Value.ToString(CultureInfo.InvariantCulture)));
            }
            catch (Exception e) { Print("Consistency Tracker: could not save the day file (" + e.Message + ")."); }
        }

        #region Properties
        [NinjaScriptProperty]
        [Display(Name = "Account name", Order = 1, GroupName = "1. Account", Description = "Leave empty to use your account automatically, or type it exactly as shown in NinjaTrader's Accounts tab (e.g. a DEMO..., Sim101 or prop account name).")]
        public string AccountName { get; set; }

        [NinjaScriptProperty]
        [Range(1, 99)]
        [Display(Name = "Best day may be at most (%)", Order = 1, GroupName = "2. Rule")]
        public double RulePercent { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "... of", Order = 2, GroupName = "2. Rule")]
        public SCHQConsistencyMode Mode { get; set; }

        [NinjaScriptProperty]
        [Range(0, double.MaxValue)]
        [Display(Name = "Profit target ($)", Order = 3, GroupName = "2. Rule", Description = "Needed when the rule is measured against the profit target.")]
        public double ProfitTarget { get; set; }

        [Display(Name = "Earlier days' results", Order = 4, GroupName = "2. Rule", Description = "Results of days before you added this indicator, e.g. 1200, -300, 450. Days after that are recorded automatically.")]
        public string EarlierDays { get; set; }

        [NinjaScriptProperty]
        [Range(0, 23)]
        [Display(Name = "New trading day starts at (hour, this PC's time)", Order = 5, GroupName = "2. Rule", Description = "18 for the CME session that starts at 6pm New York time, if this PC is on New York time.")]
        public int DayStartHour { get; set; }

        [Display(Name = "Count today's open P&L", Order = 6, GroupName = "2. Rule")]
        public bool CountOpenProfit { get; set; }

        [Range(0, double.MaxValue)]
        [Display(Name = "Minimum profit for a profitable day ($)", Order = 7, GroupName = "2. Rule")]
        public double MinDayProfit { get; set; }

        [Range(0, int.MaxValue)]
        [Display(Name = "Profitable days required (0 = none)", Order = 8, GroupName = "2. Rule")]
        public int MinDays { get; set; }

        [Range(1, 99)]
        [Display(Name = "Warn at % of today's cap", Order = 1, GroupName = "3. Warnings")]
        public double WarnPercent { get; set; }

        [Display(Name = "Pop-up alerts", Order = 2, GroupName = "3. Warnings")]
        public bool PopupAlerts { get; set; }

        [Display(Name = "Panel position", Order = 1, GroupName = "4. Panel")]
        public TextPosition PanelPosition { get; set; }
        #endregion
    }
}
