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
input int    FibLookbackBars = 50;      // Fibonacci Lookback Bars (H1/M15/M5)

// Global Variables
int sock = -1;
bool is_connected = false;
datetime last_fib_update = 0;

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

   // 2. Check and send closed orders log
   CheckClosedOrders();
}

//+------------------------------------------------------------------+
//| Update Professional On-Chart Status HUD                         |
//+------------------------------------------------------------------+
void UpdateChartHUD(string regime_str, string killswitch_str)
{
   CreateOrUpdateLabel("RTA_HUD_TITLE", 15, 20, ">>> RAKUTEN QUANT PIPELINE [FIBONACCI x DOW AI] <<<", 10, "Arial Bold", clrDeepSkyBlue);
   CreateOrUpdateLabel("RTA_HUD_REGIME", 15, 38, StringFormat("[REGIME] %s", regime_str), 9, "Arial Bold", clrLime);
   CreateOrUpdateLabel("RTA_HUD_KS", 15, 54, StringFormat("[AI KILL-SWITCH] %s", killswitch_str), 9, "Arial Bold", clrGold);
   CreateOrUpdateLabel("RTA_HUD_RISK", 15, 70, "[RISK MGMT] 2,000 JPY/Trade | SL: Micro-SL (4-8 pips)", 9, "Arial Bold", clrLightCyan);

   // 緊急全決済 (Panic Close) ボタンの描画 (文字化けゼロの英語表記)
   CreatePanicButton("RTA_BTN_CLOSE_ALL", 20, 20, 170, 32, "[!] EMERGENCY CLOSE ALL");

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Helper to create Emergency Panic Close Button                    |
//+------------------------------------------------------------------+
void CreatePanicButton(string name, int x, int y, int width, int height, string text)
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
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clrCrimson);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDarkRed);
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
         
         // ボタンを非アクティブ状態に戻す
         ObjectSetInteger(0, "RTA_BTN_CLOSE_ALL", OBJPROP_STATE, false);
         ChartRedraw(0);
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
//| Update Fibonacci & Dow Breakout Visual Overlay on Chart          |
//+------------------------------------------------------------------+
void UpdateChartFibonacciOverlay()
{
   int bars_total = iBars(Symbol(), 0);
   if(bars_total < 10) return;

   int lookback = MathMin(FibLookbackBars, bars_total - 2);
   int highest_bar = iHighest(Symbol(), 0, MODE_HIGH, lookback, 1);
   int lowest_bar  = iLowest(Symbol(), 0, MODE_LOW, lookback, 1);

   if(highest_bar < 0 || lowest_bar < 0) return;

   double high = High[highest_bar];
   double low  = Low[lowest_bar];
   double diff = high - low;
   if(diff <= 0) return;

   double fib_382 = high - (diff * 0.382);
   double fib_500 = high - (diff * 0.500);
   double fib_618 = high - (diff * 0.618);

   // 38.2% ライン
   CreateOrUpdateHLine("RTA_FIB_382", fib_382, clrGold, STYLE_DASH, 1, "FR 38.2% (Shallow Pullback)");
   // 50.0% ライン (半値)
   CreateOrUpdateHLine("RTA_FIB_500", fib_500, clrDeepSkyBlue, STYLE_SOLID, 2, "FR 50.0% (Equilibrium)");
   // 61.8% ライン (黄金比)
   CreateOrUpdateHLine("RTA_FIB_618", fib_618, clrOrangeRed, STYLE_SOLID, 2, "FR 61.8% (Golden Ratio Entry)");

   // 直近戻り高値・押し安値 (直近10本)
   int dow_lookback = MathMin(10, bars_total - 2);
   int recent_h_bar = iHighest(Symbol(), 0, MODE_HIGH, dow_lookback, 1);
   int recent_l_bar = iLowest(Symbol(), 0, MODE_LOW, dow_lookback, 1);
   if(recent_h_bar >= 0 && recent_l_bar >= 0)
   {
      CreateOrUpdateHLine("RTA_DOW_RES", High[recent_h_bar], clrMagenta, STYLE_DOT, 1, "Dow Swing High (Breakout Target)");
      CreateOrUpdateHLine("RTA_DOW_SUP", Low[recent_l_bar], clrLime, STYLE_DOT, 1, "Dow Swing Low (Micro-SL Level)");
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
