//+------------------------------------------------------------------+
//|                                           RakutenTradeAgent.mq4  |
//|                        Copyright 2026, MT4 Trading Pipeline      |
//|                                             https://example.com  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MT4 Trading Pipeline"
#property link      "https://example.com"
#property version   "1.10"
#property strict

// WinSock API imports for Windows Socket Communication
#import "ws2_32.dll"
int WSAStartup(int wVersionRequested, uchar &lpWSAData[]);
int WSACleanup();
int socket(int af, int type, int protocol);
int connect(int s, uchar &name[], int namelen);
int send(int s, uchar &buf[], int len, int flags);
int recv(int s, uchar &buf[], int len, int flags);
int closesocket(int s);
int htons(int hostshort);
int inet_addr(uchar &cp[]);
#import

// Inputs
input string ServerHost = "127.0.0.1";  // Gateway Server IP
input int    ServerPort = 5555;         // Gateway Server Port
input double FallbackLots = 0.1;        // Fallback Lot Size
input int    MagicNumber = 888888;      // Magic Number
input int    Slippage    = 3;           // Slippage (points)
input bool   EnableAutoTrade = true;    // Enable Auto Demo Trade
input bool   EnableVisualOverlay = true;// Enable Visual Fibonacci & Dow Overlay
input ENUM_TIMEFRAMES FibTimeFrame = PERIOD_H1; // Fibonacci Higher-Timeframe
input int    FibLookbackBars = 50;      // Fibonacci Lookback Bars (H1/M15/M5)

// Global Variables
int sock = -1;
bool is_connected = false;
datetime last_fib_update = 0;
datetime last_sound_alert = 0;
double current_manual_lot = 0.50;
double current_fib_500 = 0.0;
double current_fib_618 = 0.0;

// Forward Declarations
void UpdateChartHUD(string regime_str, string killswitch_str);
void UpdateChartFibonacciOverlay();
void CreateOrUpdateRectLabel(string name, int x, int y, int width, int height, color bg_clr, color border_clr);
void CreateOrUpdateZoneRect(string name, datetime time1, double price1, datetime time2, double price2, color bg_clr);
void CreateOrUpdateLabel(string name, int x, int y, string text, int font_size, string font_name, color clr);
void CreateButton(string name, int x, int y, int width, int height, string text, color bg_clr, color border_clr);
void CreateOrUpdateHLine(string name, double price, color clr, int style, int width, string desc);
void DrawEntryMarker(int order_type, double price, double sl, double tp, double lot, int ticket);
void ExecuteOrder(int order_type, double lot, double sl_pips, double tp_pips);
void CloseAllPositions();
void MoveStopLossToBreakEven();
void AutoTrailingStop();
void CheckClosedOrders();
void ClearChartObjects();
void InitSocket();
void CloseSocket();
string SendAndReceive(string message);
void ProcessServerResponse(string json);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("[RakutenTradeAgent] Initializing EA with Fibonacci, Dow Overlay & Realtime HUD...");
   InitSocket();
   if(EnableVisualOverlay)
   {
      UpdateChartFibonacciOverlay();
      UpdateChartHUD("CONNECTING", "STANDBY");
   }
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("[RakutenTradeAgent] Deinitializing EA...");
   CloseSocket();
   ClearChartObjects();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!is_connected)
   {
      InitSocket();
      if(!is_connected)
      {
         UpdateChartHUD("OFFLINE", "DISCONNECTED");
         return;
      }
   }

   // チャートオーバーレイ＆HUDの定期更新 (1分に1回)
   if(EnableVisualOverlay && TimeCurrent() - last_fib_update >= 60)
   {
      UpdateChartFibonacciOverlay();
      UpdateChartHUD("STRONG_TREND_BULL (FIB 50-61.8%)", "ACTIVE & READY");
      last_fib_update = TimeCurrent();
   }

   // 1. Send Current Tick Data (JSON)
   string tick_json = StringFormat(
      "{\"type\":\"TICK\",\"symbol\":\"%s\",\"bid\":%.5f,\"ask\":%.5f,\"time\":\"%s\",\"volume\":%d}\n",
      Symbol(), Bid, Ask, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), Volume[0]
   );

   string response = SendAndReceive(tick_json);
   if(StringLen(response) > 0)
   {
      ProcessServerResponse(response);
   }

   // 2. 自動トレーリングストップ判定 (+10pips利益でM1スイング追従)
   AutoTrailingStop();

   // 3. Check and send closed orders log
   CheckClosedOrders();
}

//+------------------------------------------------------------------+
//| Update Professional On-Chart Status HUD                         |
//+------------------------------------------------------------------+
void UpdateChartHUD(string regime_str, string killswitch_str)
{
   // 黄金ゾーン（50.0%〜61.8%）滞在判定
   bool in_golden_zone = false;
   if(current_fib_500 > 0 && current_fib_618 > 0)
   {
      double zone_top = MathMax(current_fib_500, current_fib_618);
      double zone_bottom = MathMin(current_fib_500, current_fib_618);
      if(Bid >= zone_bottom && Ask <= zone_top)
      {
         in_golden_zone = true;
         // サウンド通知 (5分に1回のみ控えめに鳴動)
         if(TimeCurrent() - last_sound_alert >= 300)
         {
            PlaySound("alert.wav");
            last_sound_alert = TimeCurrent();
            Print("[RakutenTradeAgent] 🔔 GOLDEN ZONE ALERT: Price is inside 50.0-61.8% retracement zone!");
         }
      }
   }

   string display_regime = regime_str;
   color regime_clr = clrLime;
   if(in_golden_zone)
   {
      display_regime = ">>> IN GOLDEN ZONE (50-61.8%) - WATCH DOW BREAKOUT <<<";
      regime_clr = clrGold;
   }

   // 1. 半透明ダーク背景パネルの描画 (高さ112pxに拡張)
   CreateOrUpdateRectLabel("RTA_HUD_BG", 10, 12, 450, 112, C'10,15,28', (in_golden_zone ? clrGold : C'34,47,76'));

   // 2. HUD テキストの描画
   CreateOrUpdateLabel("RTA_HUD_TITLE", 18, 18, ">>> RAKUTEN QUANT PIPELINE [FIBONACCI x DOW AI] <<<", 10, "Arial Bold", clrDeepSkyBlue);
   CreateOrUpdateLabel("RTA_HUD_REGIME", 18, 35, StringFormat("[REGIME] %s", display_regime), 9, "Arial Bold", regime_clr);
   CreateOrUpdateLabel("RTA_HUD_KS", 18, 50, StringFormat("[AI KILL-SWITCH] %s", killswitch_str), 9, "Arial Bold", clrGold);
   CreateOrUpdateLabel("RTA_HUD_RISK", 18, 65, "[RISK MGMT] 2,000 JPY/Trade | SL: Micro-SL (4-8 pips)", 9, "Arial Bold", clrLightCyan);

   // 3. リアルタイム獲得pips・含み損益メーターの計算＆表示
   double pip_size = (Digits == 3 || Digits == 5) ? Point * 10 : Point;
   if(StringFind(Symbol(), "XAU") >= 0 || StringFind(Symbol(), "GOLD") >= 0) pip_size = 0.1;

   bool has_position = false;
   double total_pips = 0.0;
   double total_profit = 0.0;
   double active_lot = 0.0;
   string pos_type = "";

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            has_position = true;
            active_lot += OrderLots();
            total_profit += (OrderProfit() + OrderSwap());
            if(OrderType() == OP_BUY)
            {
               pos_type = "BUY";
               total_pips = (Bid - OrderOpenPrice()) / pip_size;
            }
            else if(OrderType() == OP_SELL)
            {
               pos_type = "SELL";
               total_pips = (OrderOpenPrice() - Ask) / pip_size;
            }
         }
      }
   }

   if(has_position)
   {
      color pnl_clr = (total_profit >= 0) ? clrLime : clrCrimson;
      string pnl_str = StringFormat("[OPEN PnL] %s %.2fLot | %+0.1f pips (%+0.0f JPY)", pos_type, active_lot, total_pips, total_profit);
      CreateOrUpdateLabel("RTA_HUD_PNL", 18, 80, pnl_str, 9, "Arial Bold", pnl_clr);
   }
   else
   {
      CreateOrUpdateLabel("RTA_HUD_PNL", 18, 80, "[OPEN PnL] STANDBY (No Active Position)", 9, "Arial Bold", clrDarkGray);
   }

   // 4. 直近トレード履歴（直近3件の損益）の集計＆表示
   string recent_str = "[RECENT] ";
   int found_count = 0;
   double recent_total = 0.0;
   for(int h = OrdersHistoryTotal() - 1; h >= 0 && found_count < 3; h--)
   {
      if(OrderSelect(h, SELECT_BY_POS, MODE_HISTORY))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            double p = OrderProfit() + OrderSwap();
            recent_total += p;
            string sign = (p >= 0 ? "+" : "");
            recent_str += StringFormat("%s%.0f ", sign, p);
            found_count++;
         }
      }
   }
   if(found_count > 0)
   {
      string sign_t = (recent_total >= 0 ? "+" : "");
      recent_str += StringFormat("JPY (Total: %s%.0f JPY)", sign_t, recent_total);
      color recent_clr = (recent_total >= 0 ? clrLimeGreen : clrTomato);
      CreateOrUpdateLabel("RTA_HUD_RECENT", 18, 96, recent_str, 8, "Arial", recent_clr);
   }
   else
   {
      CreateOrUpdateLabel("RTA_HUD_RECENT", 18, 96, "[RECENT] No past closed trades today", 8, "Arial", clrSilver);
   }

   // 5. ボタン群の描画
   CreateButton("RTA_BTN_CLOSE_ALL", 20, 15, 170, 26, "[!] EMERGENCY CLOSE ALL", clrCrimson, clrDarkRed);
   CreateButton("RTA_BTN_BE_LOCK", 20, 44, 170, 24, "[LOCK] BE LOCK (建値固定)", C'13,148,136', C'15,118,110');
   
   string lot_btn_text = StringFormat("[LOT: %.2fL]", current_manual_lot);
   CreateButton("RTA_BTN_LOT_TOGGLE", 20, 71, 170, 22, lot_btn_text, C'30,41,59', C'51,65,85');

   string buy_text = StringFormat("[+] BUY %.2fL", current_manual_lot);
   string sell_text = StringFormat("[-] SELL %.2fL", current_manual_lot);
   CreateButton("RTA_BTN_BUY_MANUAL", 108, 96, 82, 24, buy_text, C'22,101,52', C'21,128,61');
   CreateButton("RTA_BTN_SELL_MANUAL", 20, 96, 82, 24, sell_text, C'153,27,27', C'185,28,28');

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Helper to create or move Rectangle Background Panel              |
//+------------------------------------------------------------------+
void CreateOrUpdateRectLabel(string name, int x, int y, int width, int height, color bg_clr, color border_clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg_clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border_clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
}

//+------------------------------------------------------------------+
//| Helper to create Custom Button                                   |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int width, int height, string text, color bg_clr, color border_clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x + width);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg_clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border_clr);
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
}

//+------------------------------------------------------------------+
//| Chart Event handler (Handle Button Click)                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == "RTA_BTN_CLOSE_ALL")
      {
         Print("[RakutenTradeAgent] 🚨 EMERGENCY CLOSE ALL BUTTON CLICKED! Closing all positions...");
         CloseAllPositions();
         ObjectSetInteger(0, "RTA_BTN_CLOSE_ALL", OBJPROP_STATE, false);
         ChartRedraw(0);
      }
      else if(sparam == "RTA_BTN_BE_LOCK")
      {
         Print("[RakutenTradeAgent] 🔒 BE LOCK BUTTON CLICKED! Moving SL to Break-Even +0.5pips...");
         MoveStopLossToBreakEven();
         ObjectSetInteger(0, "RTA_BTN_BE_LOCK", OBJPROP_STATE, false);
         ChartRedraw(0);
      }
      else if(sparam == "RTA_BTN_LOT_TOGGLE")
      {
         // 0.10L -> 0.25L -> 0.50L -> 0.10L トグル
         if(current_manual_lot == 0.10) current_manual_lot = 0.25;
         else if(current_manual_lot == 0.25) current_manual_lot = 0.50;
         else current_manual_lot = 0.10;

         PrintFormat("[RakutenTradeAgent] 🔄 Manual Lot toggled to: %.2f Lot", current_manual_lot);
         ObjectSetString(0, "RTA_BTN_LOT_TOGGLE", OBJPROP_TEXT, StringFormat("[LOT: %.2fL]", current_manual_lot));
         ObjectSetString(0, "RTA_BTN_BUY_MANUAL", OBJPROP_TEXT, StringFormat("[+] BUY %.2fL", current_manual_lot));
         ObjectSetString(0, "RTA_BTN_SELL_MANUAL", OBJPROP_TEXT, StringFormat("[-] SELL %.2fL", current_manual_lot));
         ObjectSetInteger(0, "RTA_BTN_LOT_TOGGLE", OBJPROP_STATE, false);
         ChartRedraw(0);
      }
      else if(sparam == "RTA_BTN_BUY_MANUAL")
      {
         PrintFormat("[RakutenTradeAgent] 🎯 MANUAL BUY %.2fLot (SL: 4.0pips, TP: 15.0pips) Triggered!", current_manual_lot);
         ExecuteOrder(OP_BUY, current_manual_lot, 4.0, 15.0);
         ObjectSetInteger(0, "RTA_BTN_BUY_MANUAL", OBJPROP_STATE, false);
         ChartRedraw(0);
      }
      else if(sparam == "RTA_BTN_SELL_MANUAL")
      {
         PrintFormat("[RakutenTradeAgent] 🎯 MANUAL SELL %.2fLot (SL: 4.0pips, TP: 15.0pips) Triggered!", current_manual_lot);
         ExecuteOrder(OP_SELL, current_manual_lot, 4.0, 15.0);
         ObjectSetInteger(0, "RTA_BTN_SELL_MANUAL", OBJPROP_STATE, false);
         ChartRedraw(0);
      }
   }
}

//+------------------------------------------------------------------+
//| Move StopLoss of all open positions to Break-Even (+0.5pips)     |
//+------------------------------------------------------------------+
void MoveStopLossToBreakEven()
{
   double pip_size = (Digits == 3 || Digits == 5) ? Point * 10 : Point;
   if(StringFind(Symbol(), "XAU") >= 0 || StringFind(Symbol(), "GOLD") >= 0) pip_size = 0.1;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            double open_price = OrderOpenPrice();
            double current_sl = OrderStopLoss();
            double new_sl = 0;

            if(OrderType() == OP_BUY)
            {
               new_sl = open_price + (0.5 * pip_size); // 建値 +0.5pips
               if(current_sl < new_sl && Bid > new_sl + (1.0 * pip_size))
               {
                  bool res = OrderModify(OrderTicket(), open_price, new_sl, OrderTakeProfit(), 0, clrLime);
                  if(res) PrintFormat("[RakutenTradeAgent] 🔒 BUY #%d SL moved to Break-Even: %.5f", OrderTicket(), new_sl);
               }
            }
            else if(OrderType() == OP_SELL)
            {
               new_sl = open_price - (0.5 * pip_size); // 建値 -0.5pips
               if((current_sl == 0 || current_sl > new_sl) && Ask < new_sl - (1.0 * pip_size))
               {
                  bool res = OrderModify(OrderTicket(), open_price, new_sl, OrderTakeProfit(), 0, clrCrimson);
                  if(res) PrintFormat("[RakutenTradeAgent] 🔒 SELL #%d SL moved to Break-Even: %.5f", OrderTicket(), new_sl);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Auto-Trailing Stop (+10pips profit -> Trail M1 Swings)           |
//+------------------------------------------------------------------+
void AutoTrailingStop()
{
   double pip_size = (Digits == 3 || Digits == 5) ? Point * 10 : Point;
   if(StringFind(Symbol(), "XAU") >= 0 || StringFind(Symbol(), "GOLD") >= 0) pip_size = 0.1;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            double open_price = OrderOpenPrice();
            double current_sl = OrderStopLoss();

            if(OrderType() == OP_BUY)
            {
               double profit_pips = (Bid - open_price) / pip_size;
               if(profit_pips >= 10.0) // +10pips以上でトレーリング開始
               {
                  int lowest_bar = iLowest(Symbol(), 0, MODE_LOW, 3, 1);
                  if(lowest_bar >= 0)
                  {
                     double trail_sl = Low[lowest_bar] - (1.0 * pip_size);
                     if(trail_sl > current_sl && trail_sl < Bid - (2.0 * pip_size))
                     {
                        bool res = OrderModify(OrderTicket(), open_price, trail_sl, OrderTakeProfit(), 0, clrDodgerBlue);
                        if(res) PrintFormat("[RakutenTradeAgent] 📈 BUY #%d Trailing SL updated: %.5f (+%.1fpips profit)", OrderTicket(), trail_sl, profit_pips);
                     }
                  }
               }
            }
            else if(OrderType() == OP_SELL)
            {
               double profit_pips = (open_price - Ask) / pip_size;
               if(profit_pips >= 10.0) // +10pips以上でトレーリング開始
               {
                  int highest_bar = iHighest(Symbol(), 0, MODE_HIGH, 3, 1);
                  if(highest_bar >= 0)
                  {
                     double trail_sl = High[highest_bar] + (1.0 * pip_size);
                     if((current_sl == 0 || trail_sl < current_sl) && trail_sl > Ask + (2.0 * pip_size))
                     {
                        bool res = OrderModify(OrderTicket(), open_price, trail_sl, OrderTakeProfit(), 0, clrDodgerBlue);
                        if(res) PrintFormat("[RakutenTradeAgent] 📉 SELL #%d Trailing SL updated: %.5f (+%.1fpips profit)", OrderTicket(), trail_sl, profit_pips);
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper to create or move Screen Label                            |
//+------------------------------------------------------------------+
void CreateOrUpdateLabel(string name, int x, int y, string text, int font_size, string font_name, color clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, font_size);
   ObjectSetString(0, name, OBJPROP_FONT, font_name);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
}

//+------------------------------------------------------------------+
//| Helper to create or move Rectangle Zone on Chart                 |
//+------------------------------------------------------------------+
void CreateOrUpdateZoneRect(string name, datetime time1, double price1, datetime time2, double price2, color bg_clr)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, time1, price1, time2, price2);
   }
   else
   {
      ObjectSetInteger(0, name, OBJPROP_TIME1, time1);
      ObjectSetDouble(0, name, OBJPROP_PRICE1, price1);
      ObjectSetInteger(0, name, OBJPROP_TIME2, time2);
      ObjectSetDouble(0, name, OBJPROP_PRICE2, price2);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, bg_clr);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg_clr);
   ObjectSetInteger(0, name, OBJPROP_BACK, true); // 背景に敷く
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
}

//+------------------------------------------------------------------+
//| Update Fibonacci & Dow Breakout Visual Overlay on Chart (MTF)    |
//+------------------------------------------------------------------+
void UpdateChartFibonacciOverlay()
{
   // 上位足 (H1 / M15) からスイング高安値を自動逆算
   ENUM_TIMEFRAMES htf = FibTimeFrame;
   if(Period() >= PERIOD_H1) htf = PERIOD_CURRENT;

   int bars_total = iBars(Symbol(), htf);
   if(bars_total < 10) return;

   int lookback = MathMin(FibLookbackBars, bars_total - 2);
   int highest_bar = iHighest(Symbol(), htf, MODE_HIGH, lookback, 1);
   int lowest_bar  = iLowest(Symbol(), htf, MODE_LOW, lookback, 1);

   if(highest_bar < 0 || lowest_bar < 0) return;

   double high = iHigh(Symbol(), htf, highest_bar);
   double low  = iLow(Symbol(), htf, lowest_bar);
   double diff = high - low;
   if(diff <= 0) return;

   double fib_382 = high - (diff * 0.382);
   double fib_500 = high - (diff * 0.500);
   double fib_618 = high - (diff * 0.618);

   current_fib_500 = fib_500;
   current_fib_618 = fib_618;

   // 1. フィボナッチ黄金比帯 (50.0%〜61.8%) の半透明ハイライトゾーン描画
   datetime t_start = TimeCurrent() - (86400 * 5); // 5日前から
   datetime t_end   = TimeCurrent() + (86400 * 2); // 2日先まで
   CreateOrUpdateZoneRect("RTA_FIB_GOLDEN_ZONE", t_start, fib_500, t_end, fib_618, C'20,35,55');

   // 2. 38.2% / 50.0% / 61.8% ライン ＆ 価格テキスト
   CreateOrUpdateHLine("RTA_FIB_382", fib_382, clrGold, STYLE_DASH, 1, StringFormat("HTF FR 38.2%% (%.3f)", fib_382));
   CreateOrUpdateHLine("RTA_FIB_500", fib_500, clrDeepSkyBlue, STYLE_SOLID, 2, StringFormat("HTF FR 50.0%% Equilibrium (%.3f)", fib_500));
   CreateOrUpdateHLine("RTA_FIB_618", fib_618, clrOrangeRed, STYLE_SOLID, 2, StringFormat("HTF FR 61.8%% Golden Zone (%.3f)", fib_618));

   // 3. 現在足の直近戻り高値・押し安値 (直近10本)
   int current_bars = iBars(Symbol(), 0);
   int dow_lookback = MathMin(10, current_bars - 2);
   int recent_h_bar = iHighest(Symbol(), 0, MODE_HIGH, dow_lookback, 1);
   int recent_l_bar = iLowest(Symbol(), 0, MODE_LOW, dow_lookback, 1);
   if(recent_h_bar >= 0 && recent_l_bar >= 0)
   {
      CreateOrUpdateHLine("RTA_DOW_RES", High[recent_h_bar], clrMagenta, STYLE_DOT, 1, StringFormat("Dow Swing High (%.3f)", High[recent_h_bar]));
      CreateOrUpdateHLine("RTA_DOW_SUP", Low[recent_l_bar], clrLime, STYLE_DOT, 1, StringFormat("Dow Swing Low (%.3f)", Low[recent_l_bar]));
   }

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Helper to create or move Horizontal Line                         |
//+------------------------------------------------------------------+
void CreateOrUpdateHLine(string name, double price, color clr, int style, int width, string desc)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   }
   else
   {
      ObjectMove(0, name, 0, 0, price);
   }
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_BACK, false); // 前面に表示
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, true);
   ObjectSetString(0, name, OBJPROP_TEXT, desc);
}

//+------------------------------------------------------------------+
//| Draw Entry Marker & SL/TP Lines on Chart                        |
//+------------------------------------------------------------------+
void DrawEntryMarker(int order_type, double price, double sl, double tp, double lot, int ticket)
{
   if(!EnableVisualOverlay) return;

   datetime t = TimeCurrent();
   string arrow_name = StringFormat("RTA_ARROW_%d", ticket);
   int arrow_code = (order_type == OP_BUY) ? 233 : 234; // 233: Up Arrow, 234: Down Arrow
   color arrow_clr = (order_type == OP_BUY) ? clrLime : clrRed;

   ObjectCreate(0, arrow_name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, arrow_name, OBJPROP_ARROWCODE, arrow_code);
   ObjectSetInteger(0, arrow_name, OBJPROP_COLOR, arrow_clr);
   ObjectSetInteger(0, arrow_name, OBJPROP_WIDTH, 3);

   // SL / TP 水平ライン
   string sl_name = StringFormat("RTA_SL_%d", ticket);
   string tp_name = StringFormat("RTA_TP_%d", ticket);
   CreateOrUpdateHLine(sl_name, sl, clrCrimson, STYLE_DASH, 1, StringFormat("#%d SL", ticket));
   CreateOrUpdateHLine(tp_name, tp, clrDodgerBlue, STYLE_DASH, 1, StringFormat("#%d TP", ticket));

   // ラベル
   string label_name = StringFormat("RTA_LBL_%d", ticket);
   ObjectCreate(0, label_name, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, label_name, OBJPROP_TEXT, StringFormat(" #%d %s (%.2f Lot)", ticket, (order_type == OP_BUY ? "BUY" : "SELL"), lot));
   ObjectSetInteger(0, label_name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, label_name, OBJPROP_FONTSIZE, 9);
}

//+------------------------------------------------------------------+
//| Clear all Custom Chart Objects                                   |
//+------------------------------------------------------------------+
void ClearChartObjects()
{
   ObjectsDeleteAll(0, "RTA_");
}

//+------------------------------------------------------------------+
//| Initialize Windows TCP Socket                                   |
//+------------------------------------------------------------------+
void InitSocket()
{
   uchar wsaData[400];
   ArrayInitialize(wsaData, 0);

   if(WSAStartup(0x202, wsaData) != 0)
   {
      Print("[RakutenTradeAgent] WSAStartup failed");
      return;
   }

   sock = socket(2, 1, 6); // AF_INET=2, SOCK_STREAM=1, IPPROTO_TCP=6
   if(sock < 0)
   {
      Print("[RakutenTradeAgent] socket() creation failed");
      return;
   }

   uchar server_ip[];
   StringToCharArray(ServerHost, server_ip);

   int addr = inet_addr(server_ip);
   int port_net = htons(ServerPort);

   uchar sockaddr_in[16];
   ArrayInitialize(sockaddr_in, 0);
   sockaddr_in[0] = 2; // AF_INET low byte
   sockaddr_in[1] = 0; // AF_INET high byte
   sockaddr_in[2] = (uchar)(port_net & 0xFF);
   sockaddr_in[3] = (uchar)((port_net >> 8) & 0xFF);
   sockaddr_in[4] = (uchar)(addr & 0xFF);
   sockaddr_in[5] = (uchar)((addr >> 8) & 0xFF);
   sockaddr_in[6] = (uchar)((addr >> 16) & 0xFF);
   sockaddr_in[7] = (uchar)((addr >> 24) & 0xFF);

   if(connect(sock, sockaddr_in, 16) != 0)
   {
      closesocket(sock);
      sock = -1;
      is_connected = false;
      return;
   }

   is_connected = true;
   PrintFormat("[RakutenTradeAgent] Successfully connected to Gateway %s:%d", ServerHost, ServerPort);
}

//+------------------------------------------------------------------+
//| Close Windows TCP Socket                                        |
//+------------------------------------------------------------------+
void CloseSocket()
{
   if(sock >= 0)
   {
      closesocket(sock);
      sock = -1;
   }
   WSACleanup();
   is_connected = false;
   Print("[RakutenTradeAgent] Socket connection closed.");
}

//+------------------------------------------------------------------+
//| Send String & Receive Response                                   |
//+------------------------------------------------------------------+
string SendAndReceive(string message)
{
   if(sock < 0) return "";

   uchar send_buf[];
   int len = StringToCharArray(message, send_buf) - 1;

   int sent = send(sock, send_buf, len, 0);
   if(sent <= 0)
   {
      Print("[RakutenTradeAgent] Send failed. Reconnecting...");
      CloseSocket();
      return "";
   }

   uchar recv_buf[4096];
   ArrayInitialize(recv_buf, 0);
   int received = recv(sock, recv_buf, 4095, 0);
   if(received <= 0)
   {
      return "";
   }

   string res = CharArrayToString(recv_buf, 0, received);
   return res;
}

//+------------------------------------------------------------------+
//| Helper to parse double value from simple JSON                    |
//+------------------------------------------------------------------+
double ParseJsonDouble(string json, string key, double default_val)
{
   string pattern = "\"" + key + "\":";
   int pos = StringFind(json, pattern);
   if(pos < 0) return default_val;

   pos += StringLen(pattern);
   int end_comma = StringFind(json, ",", pos);
   int end_brace = StringFind(json, "}", pos);
   int end_pos = (end_comma > 0 && (end_comma < end_brace || end_brace < 0)) ? end_comma : end_brace;

   if(end_pos > pos)
   {
      string val_str = StringSubstr(json, pos, end_pos - pos);
      StringTrimLeft(val_str);
      StringTrimRight(val_str);
      return StringToDouble(val_str);
   }
   return default_val;
}

//+------------------------------------------------------------------+
//| Process Gateway Signal JSON                                     |
//+------------------------------------------------------------------+
void ProcessServerResponse(string json)
{
   double lot = ParseJsonDouble(json, "lot", FallbackLots);
   double sl_pips = ParseJsonDouble(json, "stop_loss_pips", 20.0);
   double tp_pips = ParseJsonDouble(json, "take_profit_pips", 40.0);

   if(StringFind(json, "\"action\":\"BUY\"") >= 0)
   {
      ExecuteOrder(OP_BUY, lot, sl_pips, tp_pips);
   }
   else if(StringFind(json, "\"action\":\"SELL\"") >= 0)
   {
      ExecuteOrder(OP_SELL, lot, sl_pips, tp_pips);
   }
   else if(StringFind(json, "\"action\":\"CLOSE_ALL\"") >= 0)
   {
      CloseAllPositions();
   }
}

//+------------------------------------------------------------------+
//| Execute Order with Dynamic ATR SL/TP & Sizing                   |
//+------------------------------------------------------------------+
void ExecuteOrder(int order_type, double lot, double sl_pips, double tp_pips)
{
   if(!EnableAutoTrade) return;

   // Check if already in position for this MagicNumber
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            return; // 既にポジション保有中のため見送り
         }
      }
   }

   double price = (order_type == OP_BUY) ? Ask : Bid;
   double pip_size = (Digits == 3 || Digits == 5) ? Point * 10 : Point;
   if(StringFind(Symbol(), "XAU") >= 0 || StringFind(Symbol(), "GOLD") >= 0)
   {
      pip_size = 0.1; // ゴールド対応
   }

   double sl = 0;
   double tp = 0;

   if(order_type == OP_BUY)
   {
      sl = price - (sl_pips * pip_size);
      tp = price + (tp_pips * pip_size);
   }
   else
   {
      sl = price + (sl_pips * pip_size);
      tp = price - (tp_pips * pip_size);
   }

   // ロットの丸め
   lot = MathMax(MarketInfo(Symbol(), MODE_MINLOT), MathMin(MarketInfo(Symbol(), MODE_MAXLOT), lot));

   color clr = (order_type == OP_BUY) ? clrBlue : clrRed;
   int ticket = OrderSend(Symbol(), order_type, lot, price, Slippage, sl, tp, "GatewayATRAuto", MagicNumber, 0, clr);

   if(ticket > 0)
   {
      PrintFormat("[RakutenTradeAgent] 🎯 Order executed: Ticket #%d, %s, Lot: %.2f, Price: %.5f, SL: %.5f (%.1f pips), TP: %.5f (%.1f pips)",
         ticket, (order_type == OP_BUY ? "BUY" : "SELL"), lot, price, sl, sl_pips, tp, tp_pips
      );
      
      // チャート上にエントリーマークとSL/TPを描画
      DrawEntryMarker(order_type, price, sl, tp, lot, ticket);

      // マルチモーダルAI評価用: エントリー瞬間のチャート画像を自動保存
      string shot_file = StringFormat("trades\\ticket_%d.png", ticket);
      if(WindowScreenShot(shot_file, 1280, 720))
      {
         PrintFormat("[RakutenTradeAgent] 📸 Saved entry chart screenshot to MQL4/Files/%s", shot_file);
      }

      // オープン約定ログを送信 (スクリーンショットパスをコメントに付与)
      string comment_str = StringFormat("AutoOrder_FibDow_%s", shot_file);
      string trade_json = StringFormat(
         "{\"type\":\"TRADE_LOG\",\"ticket\":%d,\"symbol\":\"%s\",\"action\":\"%s\",\"lots\":%.2f,\"open_price\":%.5f,\"open_time\":\"%s\",\"profit\":0.0,\"comment\":\"%s\"}\n",
         ticket, Symbol(), (order_type == OP_BUY ? "BUY" : "SELL"), lot, price, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), comment_str
      );
      SendAndReceive(trade_json);
   }
   else
   {
      PrintFormat("[RakutenTradeAgent] ❌ OrderSend failed. Error: %d", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Close all active positions                                       |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            double close_price = (OrderType() == OP_BUY) ? Bid : Ask;
            bool res = OrderClose(OrderTicket(), OrderLots(), close_price, Slippage, clrYellow);
            if(!res)
            {
               PrintFormat("[RakutenTradeAgent] ❌ OrderClose failed for Ticket #%d. Error: %d", OrderTicket(), GetLastError());
            }
            else
            {
               PrintFormat("[RakutenTradeAgent] ✅ Position closed: Ticket #%d", OrderTicket());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check closed orders and report to Gateway                        |
//+------------------------------------------------------------------+
void CheckClosedOrders()
{
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
         {
            // 直近5分以内にクローズされた注文を通知
            if(TimeCurrent() - OrderCloseTime() < 300)
            {
               string action = (OrderType() == OP_BUY ? "BUY" : "SELL");
               string trade_json = StringFormat(
                  "{\"type\":\"TRADE_LOG\",\"ticket\":%d,\"symbol\":\"%s\",\"action\":\"%s\",\"lots\":%.2f,\"open_price\":%.5f,\"close_price\":%.5f,\"open_time\":\"%s\",\"close_time\":\"%s\",\"profit\":%.2f,\"comment\":\"ClosedTrade\"}\n",
                  OrderTicket(), OrderSymbol(), action, OrderLots(), OrderOpenPrice(), OrderClosePrice(),
                  TimeToString(OrderOpenTime(), TIME_DATE|TIME_SECONDS),
                  TimeToString(OrderCloseTime(), TIME_DATE|TIME_SECONDS),
                  OrderProfit()
               );
               SendAndReceive(trade_json);
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
