//+------------------------------------------------------------------+
//| SCHQ Consistency Rule Tracker                                     |
//| Many prop firms have a "consistency rule": your best single day   |
//| may not be more than X% of your total profit (or of the profit    |
//| target). This indicator reads the account's closed trades, groups |
//| them by trading day, and shows on the chart how close you are,    |
//| how much more you can make today without breaking the rule, and   |
//| how much more total profit you need if it is already broken.      |
//| It never places or closes trades.                                 |
//|                                                                    |
//| SignalCheckerHQ · https://signalcheckerhq.org                     |
//| License: Mozilla Public License 2.0                               |
//+------------------------------------------------------------------+
#property copyright   "SignalCheckerHQ"
#property link        "https://signalcheckerhq.org"
#property version     "1.00"
#property description "Consistency rule of a prop-firm account on the chart: best day vs total profit, today's room, profit still needed."
#property description "It reads the account only. It never opens, changes or closes trades."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

enum ENUM_CONS_MODE
  {
   CONS_OF_TOTAL  = 0, // Best day vs total profit
   CONS_OF_TARGET = 1  // Best day vs the profit target
  };

//--- inputs
input group "Rule (copy it from your prop firm)"
input double         InpRulePct       = 40.0;           // Best day may be at most this % of ...
input ENUM_CONS_MODE InpMode          = CONS_OF_TOTAL;  // ... total profit or the profit target
input double         InpTarget        = 0;              // Profit target in money (needed for "of the profit target")
input datetime       InpStartDate     = D'1970.01.01';  // Count trades from this date (start of the challenge or payout period; 1970 = whole account history)
input int            InpDayStartHour  = 0;              // New trading day starts at this server hour
input bool           InpCountOpen     = false;          // Count today's open profit/loss too
input double         InpMinDayProfit  = 0;              // Minimum profit for a day to count as a profitable day (0 = any profit)
input int            InpMinDays       = 0;              // Profitable days the firm requires (0 = none)

input group "Warnings"
input double         InpWarnPct       = 80.0;           // Warn when today has used this % of its room
input bool           InpPopup         = true;           // Pop-up alert
input bool           InpPush          = false;          // Push notification to the MetaTrader phone app

input group "Panel"
input ENUM_BASE_CORNER InpCorner      = CORNER_LEFT_LOWER; // Panel corner (bottom left, so it sits next to Prop Rule Guard)
input int            InpX             = 12;             // Distance from the side (px)
input int            InpY             = 30;             // Distance from the top/bottom (px)
input int            InpFontSize      = 9;              // Font size

//--- state
string   g_prefix = "SCHQ_CRT_";
int      g_lastState = -1;
const color C_OK   = clrMediumSeaGreen;
const color C_WARN = clrOrange;
const color C_BAD  = clrTomato;
const color C_TEXT = clrGainsboro;
const color C_DIM  = clrDarkGray;
const int   LINES  = 11;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRulePct <= 0 || InpRulePct >= 100 || InpWarnPct <= 0 || InpWarnPct >= 100)
     {
      Print("Consistency Tracker: the rule % and the warning % must be between 0 and 100.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMode == CONS_OF_TARGET && InpTarget <= 0)
     {
      Print("Consistency Tracker: set the profit target (money) to use \"of the profit target\".");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpDayStartHour < 0 || InpDayStartHour > 23)
     {
      Print("Consistency Tracker: the day start hour must be 0–23.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   CreatePanel();
   EventSetTimer(2);
   Update();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const int begin, const double &price[])
  {
   return(rates_total);   // the panel is refreshed by the timer
  }

void OnTimer() { Update(); }

//+------------------------------------------------------------------+
//| Trading day a time belongs to (start of that day, server time)   |
//+------------------------------------------------------------------+
datetime TradingDay(datetime t)
  {
   datetime shifted = t - InpDayStartHour * 3600;
   return(shifted - (shifted % 86400) + InpDayStartHour * 3600);
  }

//+------------------------------------------------------------------+
//| Closed-trade result per trading day since the start date.        |
//| A deal's result = profit + swap + commission + fee.              |
//| Deposits, withdrawals and other balance entries are ignored.     |
//+------------------------------------------------------------------+
int DailyResults(datetime &dayKeys[], double &dayPnl[])
  {
   ArrayResize(dayKeys, 0);
   ArrayResize(dayPnl, 0);
   if(!HistorySelect(InpStartDate, TimeTradeServer() + 60))
      return(0);
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      long type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      double r = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP)
                 + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_FEE);
      datetime d = TradingDay((datetime)HistoryDealGetInteger(t, DEAL_TIME));
      int k = ArraySize(dayKeys);
      int found = -1;
      for(int j = k - 1; j >= 0; j--)   // deals come in time order, so the match is usually the last day
         if(dayKeys[j] == d)
           {
            found = j;
            break;
           }
      if(found < 0)
        {
         ArrayResize(dayKeys, k + 1);
         ArrayResize(dayPnl, k + 1);
         dayKeys[k] = d;
         dayPnl[k]  = 0;
         found = k;
        }
      dayPnl[found] += r;
     }
   return(ArraySize(dayKeys));
  }

//+------------------------------------------------------------------+
void Update()
  {
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   datetime today = TradingDay(TimeTradeServer());
   datetime keys[];
   double   pnl[];
   int nDays = DailyResults(keys, pnl);

//--- split into earlier days and today
   double todayPnl = 0, other = 0, bestOther = 0;
   datetime bestDay = 0;
   int tradedDays = 0, goodDays = 0;
   for(int i = 0; i < nDays; i++)
     {
      if(keys[i] == today)
        {
         todayPnl += pnl[i];
         continue;
        }
      other += pnl[i];
      tradedDays++;
      if(IsGoodDay(pnl[i]))
         goodDays++;
      if(pnl[i] > bestOther)
        {
         bestOther = pnl[i];
         bestDay   = keys[i];
        }
     }
   if(InpCountOpen)
      todayPnl += AccountInfoDouble(ACCOUNT_PROFIT);   // floating P&L of open positions
   bool tradedToday = (todayPnl != 0);
   if(tradedToday)
     {
      tradedDays++;
      if(IsGoodDay(todayPnl))
         goodDays++;
     }

//--- the rule
   double x      = InpRulePct / 100.0;
   double total  = other + todayPnl;
   double best   = MathMax(bestOther, MathMax(0, todayPnl));
   bool   bestIsToday = (todayPnl > bestOther && todayPnl > 0);
   double allowed, needMore = 0, capToday, share;
   if(InpMode == CONS_OF_TARGET)
     {
      allowed  = x * InpTarget;
      capToday = allowed;
      share    = 100.0 * best / InpTarget;
     }
   else
     {
      allowed  = (total > 0) ? x * total : 0;
      if(best > 0)
         needMore = MathMax(0, best / x - total);
      // largest profit T today with T <= x * (other + T)  ->  T <= x * other / (1 - x)
      capToday = (other > 0) ? x * other / (1 - x) : 0;
      share    = (total > 0) ? 100.0 * best / total : (best > 0 ? 100.0 : 0.0);
     }
   double roomToday = capToday - todayPnl;
   bool ruleOk = (best <= 0) || (best <= allowed + 0.005);
   int state = 0;
   if(!ruleOk)
      state = 2;
   else
      if(capToday > 0 && todayPnl >= capToday * InpWarnPct / 100.0)
         state = 1;

//--- panel
   string L[];
   color  C[];
   ArrayResize(L, LINES);
   ArrayResize(C, LINES);
   string ruleText = (InpMode == CONS_OF_TARGET)
                     ? StringFormat("best day ≤ %.0f%% of the %s target", InpRulePct, Money(InpTarget, ccy))
                     : StringFormat("best day ≤ %.0f%% of total profit", InpRulePct);
   L[0] = "Consistency Rule Tracker · SignalCheckerHQ";
   C[0] = C_TEXT;
   L[1] = "Rule: " + ruleText + (InpStartDate < D'2000.01.01' ? " · whole account history" : " · since " + TimeToString(InpStartDate, TIME_DATE));
   C[1] = C_DIM;
   L[2] = StringFormat("Total profit %s · today %s%s", Money(total, ccy), Money(todayPnl, ccy), InpCountOpen ? " (with open trades)" : "");
   C[2] = C_TEXT;
   if(best > 0)
      L[3] = StringFormat("Best day %s (%s) = %.1f%% of %s", Money(best, ccy),
                          bestIsToday ? "today" : TimeToString(bestDay, TIME_DATE), share,
                          InpMode == CONS_OF_TARGET ? "the target" : "total profit");
   else
      L[3] = "Best day: no profitable day yet";
   C[3] = StateColor(state);
   if(InpMode == CONS_OF_TARGET)
      L[4] = StringFormat("Allowed best day: %s", Money(allowed, ccy));
   else
      L[4] = (best > 0 && !ruleOk) ? StringFormat("Rule broken now: %s more total profit needed (best day stays %s)", Money(needMore, ccy), Money(best, ccy))
             : StringFormat("Allowed best day at this total: %s", Money(allowed, ccy));
   C[4] = ruleOk ? C_TEXT : C_BAD;
   if(capToday > 0)
      L[5] = (roomToday > 0) ? StringFormat("Today can make up to %s more (cap %s)", Money(roomToday, ccy), Money(capToday, ccy))
             : StringFormat("Today is over its cap of %s by %s", Money(capToday, ccy), Money(-roomToday, ccy));
   else
      L[5] = "Today: no room yet (no earlier profit, so any profit today is 100% of the total)";
   C[5] = (capToday > 0 && roomToday > 0) ? StateColor(state == 2 ? 0 : state) : C_WARN;
   if(InpMinDays > 0)
      L[6] = StringFormat("Profitable days%s: %d of %d required", InpMinDayProfit > 0 ? " (≥ " + Money(InpMinDayProfit, ccy) + ")" : "", goodDays, InpMinDays);
   else
      L[6] = StringFormat("Days traded %d · profitable days%s %d", tradedDays, InpMinDayProfit > 0 ? " (≥ " + Money(InpMinDayProfit, ccy) + ")" : "", goodDays);
   C[6] = (InpMinDays > 0 && goodDays < InpMinDays) ? C_WARN : C_TEXT;
   L[7] = StatusLine(state, ruleOk);
   C[7] = StateColor(state);
   L[8] = "Days start at " + IntegerToString(InpDayStartHour) + ":00 server time. Closed trades incl. fees and swap.";
   C[8] = C_DIM;
   L[9] = "Check the rule against your firm's current terms.";
   C[9] = C_DIM;
   L[10] = "Reads the account only. Not financial advice.";
   C[10] = C_DIM;
   DrawPanel(L, C);

//--- warning once per change of state (only upward)
   if(state != g_lastState)
     {
      if(g_lastState != -1 && state > g_lastState)
        {
         string msg = (state == 2)
                      ? "Consistency rule broken: best day " + Money(best, ccy) + StringFormat(" = %.1f%%", share) + (InpMode == CONS_OF_TOTAL ? ", " + Money(needMore, ccy) + " more total profit needed." : " of the target.")
                      : "Consistency warning: today " + Money(todayPnl, ccy) + " of its " + Money(capToday, ccy) + " cap.";
         Send("Consistency Tracker: " + msg);
        }
      g_lastState = state;
     }
  }

bool IsGoodDay(double v) { return(v > 0 && v >= InpMinDayProfit); }

color StateColor(int s) { return(s == 2 ? C_BAD : (s == 1 ? C_WARN : C_OK)); }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string StatusLine(int state, bool ruleOk)
  {
   if(!ruleOk)
      return("RULE BROKEN: keep trading small until the total catches up");
   if(state == 1)
      return("WARNING: today is close to its cap");
   return("Consistency rule OK");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Send(string msg)
  {
   Print(msg);
   if(InpPopup)
      Alert(msg);
   if(InpPush)
      SendNotification(msg);
  }

string Money(double v, string ccy) { return(DoubleToString(v, 2) + " " + ccy); }

//+------------------------------------------------------------------+
//| Panel drawing (same layout as Prop Rule Guard)                   |
//+------------------------------------------------------------------+
void CreatePanel()
  {
   string bg = g_prefix + "bg";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'16,20,28');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'45,52,64');
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsBottom() { return(InpCorner == CORNER_LEFT_LOWER || InpCorner == CORNER_RIGHT_LOWER); }
bool IsRight()  { return(InpCorner == CORNER_RIGHT_UPPER || InpCorner == CORNER_RIGHT_LOWER); }

int g_labels = 0;   // text labels created so far

//--- a chart text label holds at most 63 characters, so longer lines are wrapped at a space
const int WRAP = 60;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void AddLine(string &O[], color &K[], string s, color c)
  {
   int n = ArraySize(O);
   ArrayResize(O, n + 1);
   ArrayResize(K, n + 1);
   O[n] = s;
   K[n] = c;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void WrapLines(string &L[], color &C[], string &O[], color &K[])
  {
   ArrayResize(O, 0);
   ArrayResize(K, 0);
   for(int i = 0; i < ArraySize(L); i++)
     {
      string s = L[i];
      if(StringLen(s) == 0)
         continue;                       // empty lines are not shown
      string indent = "";
      while(StringLen(indent) + StringLen(s) > WRAP)
        {
         int room = WRAP - StringLen(indent);
         int cut = room;
         while(cut > room / 2 && StringGetCharacter(s, cut) != ' ')
            cut--;
         if(cut <= room / 2)
            cut = room;                  // no space found: cut inside the word
         AddLine(O, K, indent + StringSubstr(s, 0, cut), C[i]);
         s = StringSubstr(s, cut);
         while(StringLen(s) > 0 && StringGetCharacter(s, 0) == ' ')
            s = StringSubstr(s, 1);
         if(StringLen(indent) == 0)
           {
            // keep the original indent of the line, plus three spaces
            int lead = 0;
            while(lead < StringLen(L[i]) && StringGetCharacter(L[i], lead) == ' ')
               lead++;
            indent = StringSubstr(L[i], 0, lead) + "   ";
           }
        }
      if(StringLen(s) > 0)
         AddLine(O, K, indent + s, C[i]);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void EnsureLabels(int count)
  {
   for(int i = g_labels; i < count; i++)
     {
      string n = g_prefix + "l" + IntegerToString(i);
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, InpCorner);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR, IsBottom() ? (IsRight() ? ANCHOR_RIGHT_LOWER : ANCHOR_LEFT_LOWER)
                       : (IsRight() ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER));
      ObjectSetString(0, n, OBJPROP_FONT, i == 0 ? "Segoe UI Semibold" : "Segoe UI");
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, InpFontSize);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_ZORDER, 1);   // text above the background
     }
   if(count > g_labels)
      g_labels = count;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawPanel(string &L[], color &C[])
  {
   string O[];
   color  K[];
   WrapLines(L, C, O, K);
   int count = ArraySize(O);
   EnsureLabels(count);
   int lineH = (int)MathRound(InpFontSize * 1.9);
   int maxLen = 0;
   for(int i = 0; i < g_labels; i++)
     {
      string n = g_prefix + "l" + IntegerToString(i);
      if(i >= count)
        {
         ObjectSetString(0, n, OBJPROP_TEXT, " ");   // an empty text would show the word "Label"
         ObjectSetInteger(0, n, OBJPROP_YDISTANCE, -100);
         continue;
        }
      int row = IsBottom() ? (count - 1 - i) : i;   // bottom corners stack upward
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, InpX);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE, InpY + row * lineH);
      ObjectSetString(0, n, OBJPROP_TEXT, O[i]);
      ObjectSetInteger(0, n, OBJPROP_COLOR, K[i]);
      maxLen = MathMax(maxLen, StringLen(O[i]));
     }
// the background is placed by its top-left corner, so for right/bottom chart corners
// its distance from that chart corner is measured to its far side
   string bg = g_prefix + "bg";
   int w = (int)(maxLen * InpFontSize * 0.75) + 20;
   int h = count * lineH + 8;
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, IsRight() ? InpX - 8 + w : InpX - 8);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, IsBottom() ? InpY - 8 + h : InpY - 6);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
