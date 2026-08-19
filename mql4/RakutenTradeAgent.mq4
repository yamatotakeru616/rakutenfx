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

// Global Variables
int sock = -1;
bool is_connected = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("[RakutenTradeAgent] Initializing EA with Dynamic ATR & Spread Guard...");
   InitSocket();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("[RakutenTradeAgent] Deinitializing EA...");
   CloseSocket();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!is_connected)
   {
      InitSocket();
      if(!is_connected) return;
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
      
      // オープン約定ログを送信
      string trade_json = StringFormat(
         "{\"type\":\"TRADE_LOG\",\"ticket\":%d,\"symbol\":\"%s\",\"action\":\"%s\",\"lots\":%.2f,\"open_price\":%.5f,\"open_time\":\"%s\",\"profit\":0.0,\"comment\":\"AutoOrder_ATR\"}\n",
         ticket, Symbol(), (order_type == OP_BUY ? "BUY" : "SELL"), lot, price, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
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
            OrderClose(OrderTicket(), OrderLots(), close_price, Slippage, clrYellow);
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
