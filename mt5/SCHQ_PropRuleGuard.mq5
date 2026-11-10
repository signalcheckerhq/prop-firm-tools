//+------------------------------------------------------------------+
//| SCHQ Prop Rule Guard                                              |
//| Shows, on the chart, how much room a prop-firm account has left   |
//| before it breaks the daily loss limit or the max drawdown, how    |
//| far the profit target is, and what happens if every open stop is  |
//| hit. Warns before a rule breaks. It never places or closes trades.|
//|                                                                    |
//| SignalCheckerHQ · https://signalcheckerhq.org                     |
//| License: Mozilla Public License 2.0                               |
//+------------------------------------------------------------------+
#property copyright   "SignalCheckerHQ"
#property link        "https://signalcheckerhq.org"
#property version     "1.00"
#property description "Daily loss, max drawdown and profit target of a prop-firm account on the chart, with a warning before a rule breaks."
#property description "It reads the account only. It never opens, changes or closes trades."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- how the max drawdown floor moves
enum ENUM_DD_MODE
  {
   DD_STATIC          = 0, // Static: start balance minus the limit
   DD_TRAILING_EQUITY = 1, // Trailing: highest equity minus the limit
   DD_TRAILING_CLOSED = 2  // Trailing: highest closed balance minus the limit
  };

//--- what the daily loss limit is measured from
enum ENUM_DAILY_BASE
  {
   DAILY_BALANCE      = 0, // Balance at the start of the day
   DAILY_MAX_BAL_EQ   = 1  // Higher of balance and equity at the start of the day
  };

//--- inputs
input group "Account rules (copy them from your prop firm)"
input double         InpStartBalance   = 0;              // Starting balance of the challenge (0 = current balance when attached)
input double         InpDailyLossPct   = 5.0;            // Daily loss limit, % of starting balance
input ENUM_DAILY_BASE InpDailyBase     = DAILY_BALANCE;  // Daily loss is measured from
input double         InpMaxDDPct       = 10.0;           // Max drawdown, % of starting balance
input ENUM_DD_MODE   InpDDMode         = DD_STATIC;      // Max drawdown type
input bool           InpTrailLock      = true;           // Trailing floor stops at the starting balance
input double         InpTargetPct      = 10.0;           // Profit target, % of starting balance (0 = none)
input int            InpDayStartHour   = 0;              // New trading day starts at this server hour

input group "Warnings"
input double         InpWarnPct        = 80.0;           // Warn when this % of a limit is used
input bool           InpPopup          = true;           // Pop-up alert
input bool           InpPush           = false;          // Push notification to the MetaTrader phone app

input group "Panel"
input ENUM_BASE_CORNER InpCorner       = CORNER_LEFT_UPPER; // Panel corner
input int            InpX              = 12;             // Distance from the side (px)
input int            InpY              = 80;             // Distance from the top/bottom (px; 80 clears the one-click trading box)
input int            InpFontSize       = 9;              // Font size

//--- state
string   g_prefix;          // object name prefix
string   g_gvKey;           // global-variable key prefix for this account
double   g_start = 0;       // starting balance used
int      g_lastDailyState = -1, g_lastDDState = -1, g_lastRiskState = -1, g_lastTargetState = -1;

const color C_OK   = clrMediumSeaGreen;
const color C_WARN = clrOrange;
const color C_BAD  = clrTomato;
const color C_TEXT = clrGainsboro;
const color C_DIM  = clrDarkGray;
const int   LINES  = 12;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpDailyLossPct < 0 || InpMaxDDPct <= 0 || InpTargetPct < 0 || InpWarnPct <= 0 || InpWarnPct >= 100)
     {
      Print("Prop Rule Guard: check the inputs (limits must be positive, warning % between 0 and 100).");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpDayStartHour < 0 || InpDayStartHour > 23)
     {
      Print("Prop Rule Guard: the day start hour must be 0–23.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_prefix = "SCHQ_PRG_";
   g_gvKey  = "SCHQ_PRG_" + IntegerToString(login) + "_";

// starting balance: input, or the one remembered for this account, or the balance now
// (0 means no trading account yet: it is looked up again on every update and never remembered)
   g_start = StartBalance();

// highest equity / closed balance seen so far (for trailing drawdown)
   if(!GlobalVariableCheck(g_gvKey + "peakEq"))
      GlobalVariableSet(g_gvKey + "peakEq", MathMax(g_start, AccountInfoDouble(ACCOUNT_EQUITY)));
   if(!GlobalVariableCheck(g_gvKey + "peakBal"))
      GlobalVariableSet(g_gvKey + "peakBal", MathMax(g_start, AccountInfoDouble(ACCOUNT_BALANCE)));

   CreatePanel();
   EventSetTimer(1);
   Update();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const int begin, const double &price[])
  {
   Update();
   return(rates_total);
  }

void OnTimer() { Update(); }

//+------------------------------------------------------------------+
//| Start of the current trading day, in server time                  |
//+------------------------------------------------------------------+
datetime DayStart()
  {
   datetime now = TimeTradeServer();
   datetime midnight = now - (now % 86400);
   datetime start = midnight + InpDayStartHour * 3600;
   if(start > now)
      start -= 86400;
   return(start);
  }

//+------------------------------------------------------------------+
//| Balance at the start of the day = balance now minus every closed |
//| trade result since then (profit, swap, commission, fee).         |
//| Deposits and withdrawals are not trade results and are ignored. |
//+------------------------------------------------------------------+
double BalanceAtDayStart(datetime dayStart)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!HistorySelect(dayStart, TimeTradeServer() + 60))
      return(balance);
   double since = 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0)
         continue;
      long type = HistoryDealGetInteger(t, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      since += HistoryDealGetDouble(t, DEAL_PROFIT)
               + HistoryDealGetDouble(t, DEAL_SWAP)
               + HistoryDealGetDouble(t, DEAL_COMMISSION)
               + HistoryDealGetDouble(t, DEAL_FEE);
     }
   return(balance - since);
  }

//+------------------------------------------------------------------+
//| Money lost if every open position hits its stop now.             |
//| Returns -1 if a position has no stop (risk not limited).         |
//+------------------------------------------------------------------+
double OpenRiskToStops(int &noStop)
  {
   double risk = 0;
   noStop = 0;
   int n = PositionsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      string sym  = PositionGetString(POSITION_SYMBOL);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double sl   = PositionGetDouble(POSITION_SL);
      double cur  = PositionGetDouble(POSITION_PRICE_CURRENT);
      long   type = PositionGetInteger(POSITION_TYPE);
      if(sl <= 0)
        {
         noStop++;
         continue;
        }
      double pnl = 0;
      ENUM_ORDER_TYPE ot = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(OrderCalcProfit(ot, sym, vol, cur, sl, pnl))
        {
         if(pnl < 0)
            risk += -pnl;   // a stop already past the current price in profit adds nothing
        }
     }
   return(risk);
  }

//+------------------------------------------------------------------+
double StartBalance()
  {
   if(InpStartBalance > 0)
      return(InpStartBalance);
   if(GlobalVariableCheck(g_gvKey + "start") && GlobalVariableGet(g_gvKey + "start") > 0)
      return(GlobalVariableGet(g_gvKey + "start"));
   double b = AccountInfoDouble(ACCOUNT_BALANCE);
   if(b > 0)
      GlobalVariableSet(g_gvKey + "start", b);
   return(b);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Update()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   string ccy     = AccountInfoString(ACCOUNT_CURRENCY);

//--- no trading account logged in (or an empty one): nothing to check yet
   if(g_start <= 0)
      g_start = StartBalance();
   if(AccountInfoInteger(ACCOUNT_LOGIN) == 0 || g_start <= 0 || equity <= 0)
     {
      string W[];
      color  K[];
      ArrayResize(W, LINES);
      ArrayResize(K, LINES);
      for(int i = 0; i < LINES; i++)
        {
         W[i] = "";
         K[i] = C_DIM;
        }
      W[0] = "Prop Rule Guard · SignalCheckerHQ";
      K[0] = C_TEXT;
      W[1] = "No trading account with money in it is logged in.";
      K[1] = C_WARN;
      W[2] = "Log in to your demo or prop account (File > Login to Trade Account),";
      K[2] = C_TEXT;
      W[3] = "or set the starting balance in the inputs.";
      K[3] = C_TEXT;
      DrawPanel(W, K);
      return;
     }

//--- daily loss
   datetime ds = DayStart();
   string dayKey = g_gvKey + "day";
   double dayBase = BalanceAtDayStart(ds);
   if(InpDailyBase == DAILY_MAX_BAL_EQ)
     {
      // equity at the start of the day can only be known if the terminal was running then;
      // the first equity seen in a new day is remembered, and the higher of it and the day-start balance is used
      if(!GlobalVariableCheck(dayKey) || (datetime)GlobalVariableGet(dayKey) != ds)
        {
         GlobalVariableSet(dayKey, (double)ds);
         GlobalVariableSet(g_gvKey + "dayEq", equity);
        }
      dayBase = MathMax(dayBase, GlobalVariableGet(g_gvKey + "dayEq"));
     }
   double dailyLimit = g_start * InpDailyLossPct / 100.0;
   double dailyFloor = dayBase - dailyLimit;
   double dailyUsed  = MathMax(0, dayBase - equity);
   double dailyLeft  = equity - dailyFloor;

//--- max drawdown
   double peakEq  = MathMax(GlobalVariableGet(g_gvKey + "peakEq"), equity);
   double peakBal = MathMax(GlobalVariableGet(g_gvKey + "peakBal"), balance);
   GlobalVariableSet(g_gvKey + "peakEq", peakEq);
   GlobalVariableSet(g_gvKey + "peakBal", peakBal);
   double ddLimit = g_start * InpMaxDDPct / 100.0;
   double ddFloor = g_start - ddLimit;
   if(InpDDMode == DD_TRAILING_EQUITY)
      ddFloor = peakEq - ddLimit;
   else
      if(InpDDMode == DD_TRAILING_CLOSED)
         ddFloor = peakBal - ddLimit;
   if(InpDDMode != DD_STATIC && InpTrailLock)
      ddFloor = MathMin(ddFloor, g_start);
   double ddLeft = equity - ddFloor;
   double ddUsed = MathMax(0, ddLimit - ddLeft);

//--- the tighter of the two floors is the one that matters now
   double floorNow = MathMax(dailyFloor, ddFloor);
   double roomLeft = equity - floorNow;

//--- open risk
   int noStop = 0;
   double openRisk = OpenRiskToStops(noStop);
   double eqIfStops = equity - openRisk;

//--- profit target
   double target = (InpTargetPct > 0) ? g_start * (1 + InpTargetPct / 100.0) : 0;
   double toTarget = target - balance;   // targets count closed profit

//--- states: 0 ok, 1 warn, 2 breach
   int dailyState = StateFor(dailyUsed, dailyLimit, dailyLeft);
   int ddState    = StateFor(ddUsed, ddLimit, ddLeft);
   int riskState  = 0;
   if(noStop > 0 || eqIfStops <= floorNow)
      riskState = 2;
   else
      if(openRisk >= roomLeft * InpWarnPct / 100.0)
         riskState = 1;
   int targetState = (target > 0 && toTarget <= 0) ? 1 : 0;

//--- panel
   string L[];
   color  C[];
   ArrayResize(L, LINES);
   ArrayResize(C, LINES);
   L[0] = "Prop Rule Guard · SignalCheckerHQ";
   C[0] = C_TEXT;
   L[1] = StringFormat("Start %s   Balance %s   Equity %s", Money(g_start, ccy), Money(balance, ccy), Money(equity, ccy));
   C[1] = C_DIM;
   L[2] = StringFormat("Daily loss: %s of %s used · %s left", Money(dailyUsed, ccy), Money(dailyLimit, ccy), Money(MathMax(0, dailyLeft), ccy));
   C[2] = StateColor(dailyState);
   L[3] = StringFormat("   floor today %s (from %s at %s)", Money(dailyFloor, ccy), Money(dayBase, ccy), TimeToString(ds, TIME_DATE | TIME_MINUTES));
   C[3] = C_DIM;
   L[4] = StringFormat("Max drawdown: %s of %s used · %s left", Money(ddUsed, ccy), Money(ddLimit, ccy), Money(MathMax(0, ddLeft), ccy));
   C[4] = StateColor(ddState);
   L[5] = StringFormat("   floor %s (%s)", Money(ddFloor, ccy), DDModeText());
   C[5] = C_DIM;
   L[6] = StringFormat("Room before a rule breaks: %s", Money(MathMax(0, roomLeft), ccy));
   C[6] = StateColor(MathMax(dailyState, ddState));
   if(noStop > 0)
      L[7] = StringFormat("Open risk: %d position(s) WITHOUT a stop · loss not limited", noStop);
   else
      L[7] = StringFormat("Open risk if every stop is hit: %s → equity %s", Money(openRisk, ccy), Money(eqIfStops, ccy));
   C[7] = StateColor(riskState);
   if(target > 0)
     {
      double done = (target - g_start) > 0 ? 100.0 * (balance - g_start) / (target - g_start) : 0;
      L[8] = (toTarget <= 0) ? StringFormat("Profit target %s reached (closed balance)", Money(target, ccy))
             : StringFormat("Profit target %s: %s to go (%.0f%% done)", Money(target, ccy), Money(toTarget, ccy), MathMax(0, done));
     }
   else
      L[8] = "Profit target: none";
   C[8] = (targetState == 1) ? C_OK : C_TEXT;
   L[9]  = StatusLine(dailyState, ddState, riskState, noStop);
   C[9]  = StateColor(MathMax(MathMax(dailyState, ddState), riskState));
   L[10] = "Check these rules against your firm's current terms.";
   C[10] = C_DIM;
   L[11] = "Reads the account only. Not financial advice.";
   C[11] = C_DIM;
   DrawPanel(L, C);

//--- warnings, once per change of state
   Notify(g_lastDailyState, dailyState, "Daily loss", Money(MathMax(0, dailyLeft), ccy) + " left today");
   Notify(g_lastDDState, ddState, "Max drawdown", Money(MathMax(0, ddLeft), ccy) + " left above the floor");
   if(noStop > 0)
      Notify(g_lastRiskState, riskState, "Open risk", IntegerToString(noStop) + " position(s) have no stop");
   else
      Notify(g_lastRiskState, riskState, "Open risk", "if every stop is hit, equity would be " + Money(eqIfStops, ccy) + " (floor " + Money(floorNow, ccy) + ")");
   if(targetState != g_lastTargetState)
     {
      if(targetState == 1 && g_lastTargetState == 0)
         Send("Prop Rule Guard: profit target " + Money(target, ccy) + " reached on closed balance.");
      g_lastTargetState = targetState;
     }
  }

//+------------------------------------------------------------------+
int StateFor(double used, double limit, double left)
  {
   if(left <= 0)
      return(2);
   if(limit > 0 && used >= limit * InpWarnPct / 100.0)
      return(1);
   return(0);
  }

color StateColor(int s) { return(s == 2 ? C_BAD : (s == 1 ? C_WARN : C_OK)); }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string DDModeText()
  {
   if(InpDDMode == DD_STATIC)
      return("static");
   string s = (InpDDMode == DD_TRAILING_EQUITY) ? "trails highest equity" : "trails highest closed balance";
   if(InpTrailLock)
      s += ", stops at start";
   return(s);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string StatusLine(int d, int dd, int r, int noStop)
  {
   if(d == 2)
      return("BREACH: daily loss limit reached");
   if(dd == 2)
      return("BREACH: max drawdown floor reached");
   if(noStop > 0)
      return("WARNING: a position has no stop");
   if(r == 2)
      return("WARNING: open stops would break a rule");
   if(d == 1 || dd == 1 || r == 1)
      return("WARNING: close to a limit");
   return("All rules OK");
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void Notify(int &last, int now, string what, string detail)
  {
   if(now != last)
     {
      if(last != -1 && now > last)
        {
         string level = (now == 2) ? "BREACH" : "WARNING";
         Send("Prop Rule Guard " + level + ": " + what + ", " + detail + ".");
        }
      last = now;
     }
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

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string Money(double v, string ccy)
  {
   return(DoubleToString(v, 2) + " " + ccy);
  }

//+------------------------------------------------------------------+
//| Panel drawing                                                     |
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
