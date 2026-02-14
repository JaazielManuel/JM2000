//+------------------------------------------------------------------+
//|                                            UniversalTrailing.mqh |
//|                                  Copyright 2024, Jules AI        |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules AI"
#property link      "https://www.mql5.com"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

/*
   SISTEMA DE TRAILING STOP UNIVERSAL INTELIGENTE (INSTITUTIONAL+ VERSION)

   Esta versão inclui:
   - Ajuste dinâmico de volatilidade (ATR)
   - Filtro de Spread institucional
   - Performance otimizada com Throttling e Micro-otimizações (Cache de tipos)
   - Lógica de "True Step" (movimento em blocos)
   - Proteção rigorosa de Stop/Freeze levels (ideal para Deriv/Sintéticos)
   - Trailing estrutural (apenas move após o preço de abertura)
*/

enum ENUM_TRAILING_MODE
{
   TRL_MODE_NONE        = 0, // Nenhum (Desativado)
   TRL_MODE_ATR         = 1, // ATR (Adaptativo por Volatilidade)
   TRL_MODE_PSAR        = 2, // Parabolic SAR
   TRL_MODE_MA          = 3, // Moving Average (Tendência)
   TRL_MODE_HL          = 4, // High/Low (Máximas e Mínimas)
   TRL_MODE_FRACTALS    = 5, // Fractals (Suportes/Resistências)
   TRL_MODE_BOLLINGER   = 6, // Bollinger Bands (Volatilidade/Reversão)
   TRL_MODE_STEP        = 7, // True Step (Degrau Fixo em blocos)
   TRL_MODE_SHADOW      = 8  // Shadow (Atrás da Sombra da Vela anterior)
};

class CUniversalTrailing
{
private:
   CTrade         m_trade;
   CPositionInfo  m_position;
   CSymbolInfo    m_symbol;

   long           m_magic;
   string         m_symbol_name;

   // Performance & Throttling
   int            m_throttle_ms;

   // Parâmetros Gerais
   ENUM_TRAILING_MODE m_mode;
   double         m_max_spread;
   bool           m_only_above_entry; // Trailing apenas acima/abaixo do preço de entrada

   // ATR
   int            m_atr_period;
   double         m_atr_multiplier;
   int            m_atr_handle;

   // PSAR
   double         m_psar_step;
   double         m_psar_max;
   int            m_psar_handle;

   // MA
   int            m_ma_period;
   int            m_ma_shift;
   ENUM_MA_METHOD m_ma_method;
   ENUM_APPLIED_PRICE m_ma_price;
   int            m_ma_handle;

   // HL
   int            m_hl_candles;

   // Bollinger
   int            m_bb_period;
   double         m_bb_deviation;
   int            m_bb_handle;

   // Fractals
   int            m_fractal_handle;

   // Step
   double         m_step_size;
   double         m_step_min_profit;

   // Breakeven
   double         m_be_activation;
   double         m_be_profit;

   // Métodos auxiliares
   double         GetATRValue(int index);
   double         GetPSARValue(int index);
   double         GetMAValue(int index);
   double         GetBollingerValue(ENUM_POSITION_TYPE type, int index);
   double         GetFractalValue(ENUM_POSITION_TYPE type, int index);
   double         GetHLValue(ENUM_POSITION_TYPE type, int candles);
   double         GetShadowValue(ENUM_POSITION_TYPE type, int index);

   bool           ModifySL(long ticket, double new_sl);
   bool           IsStopLevelOk(double price, double sl, ENUM_POSITION_TYPE type);
   void           ReleaseHandles();

public:
   CUniversalTrailing();
   ~CUniversalTrailing();

   void           Init(long magic, string symbol_name);

   // Configuração
   void           SetMode(ENUM_TRAILING_MODE mode) { m_mode = mode; }
   void           SetMaxSpread(double max_spread_pts) { m_max_spread = max_spread_pts; }
   void           SetThrottle(int ms) { m_throttle_ms = ms; }
   void           SetOnlyAboveEntry(bool only) { m_only_above_entry = only; }

   void           SetATR(int period, double multiplier);
   void           SetPSAR(double step, double max);
   void           SetMA(int period, int shift, ENUM_MA_METHOD method, ENUM_APPLIED_PRICE price);
   void           SetHL(int candles) { m_hl_candles = candles; }
   void           SetBollinger(int period, double deviation);
   void           SetFractals();
   void           SetStep(double step_size, double min_profit) { m_step_size = step_size; m_step_min_profit = min_profit; }
   void           SetBreakeven(double activation, double profit) { m_be_activation = activation; m_be_profit = profit; }

   void           Process(); // Chamada principal
};

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CUniversalTrailing::CUniversalTrailing() :
   m_magic(0),
   m_symbol_name(""),
   m_mode(TRL_MODE_NONE),
   m_atr_handle(INVALID_HANDLE),
   m_psar_handle(INVALID_HANDLE),
   m_ma_handle(INVALID_HANDLE),
   m_bb_handle(INVALID_HANDLE),
   m_fractal_handle(INVALID_HANDLE),
   m_max_spread(0),
   m_throttle_ms(250),
   m_only_above_entry(true) // Padrão robusto: apenas move após o lucro
{
   m_be_activation = 0;
   m_be_profit = 0;
   m_hl_candles = 3;
   m_step_size = 100;
   m_step_min_profit = 0;
}

//+------------------------------------------------------------------+
//| Destructor                                                       |
//+------------------------------------------------------------------+
CUniversalTrailing::~CUniversalTrailing()
{
   ReleaseHandles();
}

//+------------------------------------------------------------------+
//| Release Handles                                                  |
//+------------------------------------------------------------------+
void CUniversalTrailing::ReleaseHandles()
{
   if(m_atr_handle != INVALID_HANDLE) { IndicatorRelease(m_atr_handle); m_atr_handle = INVALID_HANDLE; }
   if(m_psar_handle != INVALID_HANDLE) { IndicatorRelease(m_psar_handle); m_psar_handle = INVALID_HANDLE; }
   if(m_ma_handle != INVALID_HANDLE) { IndicatorRelease(m_ma_handle); m_ma_handle = INVALID_HANDLE; }
   if(m_bb_handle != INVALID_HANDLE) { IndicatorRelease(m_bb_handle); m_bb_handle = INVALID_HANDLE; }
   if(m_fractal_handle != INVALID_HANDLE) { IndicatorRelease(m_fractal_handle); m_fractal_handle = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
void CUniversalTrailing::Init(long magic, string symbol_name)
{
   m_magic = magic;
   m_symbol_name = symbol_name;
   m_symbol.Name(symbol_name);
   m_trade.SetExpertMagicNumber(magic);
}

//+------------------------------------------------------------------+
//| ATR Configuration                                                |
//+------------------------------------------------------------------+
void CUniversalTrailing::SetATR(int period, double multiplier)
{
   m_atr_period = period;
   m_atr_multiplier = multiplier;
   if(m_atr_handle != INVALID_HANDLE) IndicatorRelease(m_atr_handle);
   m_atr_handle = iATR(m_symbol_name, PERIOD_CURRENT, m_atr_period);
}

//+------------------------------------------------------------------+
//| PSAR Configuration                                               |
//+------------------------------------------------------------------+
void CUniversalTrailing::SetPSAR(double step, double max)
{
   m_psar_step = step;
   m_psar_max = max;
   if(m_psar_handle != INVALID_HANDLE) IndicatorRelease(m_psar_handle);
   m_psar_handle = iSAR(m_symbol_name, PERIOD_CURRENT, m_psar_step, m_psar_max);
}

//+------------------------------------------------------------------+
//| MA Configuration                                                 |
//+------------------------------------------------------------------+
void CUniversalTrailing::SetMA(int period, int shift, ENUM_MA_METHOD method, ENUM_APPLIED_PRICE price)
{
   m_ma_period = period;
   m_ma_shift = shift;
   m_ma_method = method;
   m_ma_price = price;
   if(m_ma_handle != INVALID_HANDLE) IndicatorRelease(m_ma_handle);
   m_ma_handle = iMA(m_symbol_name, PERIOD_CURRENT, m_ma_period, m_ma_shift, m_ma_method, m_ma_price);
}

//+------------------------------------------------------------------+
//| Bollinger Configuration                                          |
//+------------------------------------------------------------------+
void CUniversalTrailing::SetBollinger(int period, double deviation)
{
   m_bb_period = period;
   m_bb_deviation = deviation;
   if(m_bb_handle != INVALID_HANDLE) IndicatorRelease(m_bb_handle);
   m_bb_handle = iBands(m_symbol_name, PERIOD_CURRENT, m_bb_period, 0, m_bb_deviation, PRICE_CLOSE);
}

//+------------------------------------------------------------------+
//| Fractal Configuration                                            |
//+------------------------------------------------------------------+
void CUniversalTrailing::SetFractals()
{
   if(m_fractal_handle != INVALID_HANDLE) IndicatorRelease(m_fractal_handle);
   m_fractal_handle = iFractals(m_symbol_name, PERIOD_CURRENT);
}

//+------------------------------------------------------------------+
//| Main Process Loop                                                |
//+------------------------------------------------------------------+
void CUniversalTrailing::Process()
{
   // Performance Throttling
   static uint last_tick_ms = 0;
   if(GetTickCount() - last_tick_ms < (uint)m_throttle_ms) return;
   last_tick_ms = GetTickCount();

   if(!m_symbol.RefreshRates()) return;

   // Filtro de Spread
   if(m_max_spread > 0)
   {
      double spread = (m_symbol.Ask() - m_symbol.Bid()) / m_symbol.Point();
      if(spread > m_max_spread) return;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == m_magic && m_position.Symbol() == m_symbol_name)
         {
            // Micro-otimização: Cache de propriedades da posição
            ENUM_POSITION_TYPE type = m_position.PositionType();
            double current_sl = m_position.StopLoss();
            double open_price = m_position.PriceOpen();
            double bid = m_symbol.Bid();
            double ask = m_symbol.Ask();
            double current_price = (type == POSITION_TYPE_BUY) ? bid : ask;
            double new_sl = 0;

            // 1. Breakeven Check
            if(m_be_activation > 0)
            {
               double profit_points = (type == POSITION_TYPE_BUY) ?
                                      (bid - open_price) / m_symbol.Point() :
                                      (open_price - ask) / m_symbol.Point();

               if(profit_points >= m_be_activation)
               {
                  double be_price = (type == POSITION_TYPE_BUY) ?
                                    open_price + (m_be_profit * m_symbol.Point()) :
                                    open_price - (m_be_profit * m_symbol.Point());

                  bool can_be = false;
                  if(type == POSITION_TYPE_BUY)
                  {
                     if(current_sl < be_price) can_be = true;
                  }
                  else
                  {
                     if(current_sl > be_price || current_sl == 0) can_be = true;
                  }

                  if(can_be && IsStopLevelOk(current_price, be_price, type))
                  {
                     ModifySL(m_position.Ticket(), be_price);
                     continue;
                  }
               }
            }

            // 2. Trailing Logic
            if(m_mode == TRL_MODE_NONE) continue;

            switch(m_mode)
            {
               case TRL_MODE_ATR:
                  {
                     double atr = GetATRValue(1);
                     if(atr > 0)
                     {
                        double atr_slow = GetATRValue(10);
                        double vol_factor = (atr_slow > 0) ? (atr / atr_slow) : 1.0;
                        if(vol_factor > 1.25) vol_factor = 1.25;
                        if(vol_factor < 0.8) vol_factor = 0.8;

                        double dynamic_multiplier = m_atr_multiplier * vol_factor;

                        new_sl = (type == POSITION_TYPE_BUY) ?
                                 bid - (atr * dynamic_multiplier) :
                                 ask + (atr * dynamic_multiplier);
                     }
                  }
                  break;

               case TRL_MODE_PSAR:
                  new_sl = GetPSARValue(1);
                  break;

               case TRL_MODE_MA:
                  new_sl = GetMAValue(1);
                  break;

               case TRL_MODE_HL:
                  new_sl = GetHLValue(type, m_hl_candles);
                  break;

               case TRL_MODE_FRACTALS:
                  new_sl = GetFractalValue(type, 2);
                  break;

               case TRL_MODE_BOLLINGER:
                  new_sl = GetBollingerValue(type, 1);
                  break;

               case TRL_MODE_SHADOW:
                  new_sl = GetShadowValue(type, 1);
                  break;

               case TRL_MODE_STEP:
                  {
                     double step_pts = m_step_size * m_symbol.Point();
                     double min_prof = m_step_min_profit * m_symbol.Point();

                     if(type == POSITION_TYPE_BUY)
                     {
                        if(bid - open_price > min_prof)
                        {
                           double blocks = MathFloor((bid - open_price) / step_pts);
                           new_sl = open_price + (blocks * step_pts) - step_pts;
                        }
                     }
                     else
                     {
                        if(open_price - ask > min_prof)
                        {
                           double blocks = MathFloor((open_price - ask) / step_pts);
                           new_sl = open_price - (blocks * step_pts) + step_pts;
                        }
                     }
                  }
                  break;
            }

            // Filtro Estrutural de Entrada (Opcional - Robusto)
            if(m_only_above_entry && new_sl > 0)
            {
               if(type == POSITION_TYPE_BUY && new_sl <= open_price) new_sl = 0;
               if(type == POSITION_TYPE_SELL && new_sl >= open_price) new_sl = 0;
            }

            // Validação de Direção e Melhoria
            if(new_sl > 0)
            {
               new_sl = m_symbol.NormalizePrice(new_sl);

               bool should_modify = false;
               if(type == POSITION_TYPE_BUY)
               {
                  if(new_sl > current_sl + (m_symbol.Point() * 2) && new_sl < bid) should_modify = true;
               }
               else
               {
                  if((new_sl < current_sl - (m_symbol.Point() * 2) || current_sl == 0) && new_sl > ask) should_modify = true;
               }

               if(should_modify && IsStopLevelOk(current_price, new_sl, type))
               {
                  ModifySL(m_position.Ticket(), new_sl);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get ATR Value                                                    |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetATRValue(int index)
{
   if(m_atr_handle == INVALID_HANDLE) return 0;
   double buffer[1];
   if(CopyBuffer(m_atr_handle, 0, index, 1, buffer) < 1) return 0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get PSAR Value                                                   |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetPSARValue(int index)
{
   if(m_psar_handle == INVALID_HANDLE) return 0;
   double buffer[1];
   if(CopyBuffer(m_psar_handle, 0, index, 1, buffer) < 1) return 0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get MA Value                                                     |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetMAValue(int index)
{
   if(m_ma_handle == INVALID_HANDLE) return 0;
   double buffer[1];
   if(CopyBuffer(m_ma_handle, 0, index, 1, buffer) < 1) return 0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get Bollinger Value                                              |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetBollingerValue(ENUM_POSITION_TYPE type, int index)
{
   if(m_bb_handle == INVALID_HANDLE) return 0;
   double buffer[1];
   int buffer_index = (type == POSITION_TYPE_BUY) ? 2 : 1;
   if(CopyBuffer(m_bb_handle, buffer_index, index, 1, buffer) < 1) return 0;
   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get High/Low Value                                               |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetHLValue(ENUM_POSITION_TYPE type, int candles)
{
   if(type == POSITION_TYPE_BUY)
   {
      double lows[];
      ArraySetAsSeries(lows, true);
      if(CopyLow(m_symbol_name, PERIOD_CURRENT, 1, candles, lows) > 0)
         return lows[ArrayMinimum(lows)];
   }
   else
   {
      double highs[];
      ArraySetAsSeries(highs, true);
      if(CopyHigh(m_symbol_name, PERIOD_CURRENT, 1, candles, highs) > 0)
         return highs[ArrayMaximum(highs)];
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Get Fractal Value                                                |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetFractalValue(ENUM_POSITION_TYPE type, int index)
{
   if(m_fractal_handle == INVALID_HANDLE) SetFractals();
   double buffer[];
   ArraySetAsSeries(buffer, true);
   int buffer_idx = (type == POSITION_TYPE_BUY) ? 1 : 0;

   // Otimização: Copia apenas 30 barras em vez de 100
   if(CopyBuffer(m_fractal_handle, buffer_idx, 0, 30, buffer) > 0)
   {
      int limit = ArraySize(buffer);
      for(int i = index; i < limit; i++)
         if(buffer[i] != EMPTY_VALUE && buffer[i] > 0) return buffer[i];
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Get Shadow Value                                                 |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetShadowValue(ENUM_POSITION_TYPE type, int index)
{
   if(type == POSITION_TYPE_BUY)
   {
      double low = 0;
      if(CopyLow(m_symbol_name, PERIOD_CURRENT, index, 1, &low) > 0) return low;
   }
   else
   {
      double high = 0;
      if(CopyHigh(m_symbol_name, PERIOD_CURRENT, index, 1, &high) > 0) return high;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Modify Stop Loss                                                 |
//+------------------------------------------------------------------+
bool CUniversalTrailing::ModifySL(long ticket, double new_sl)
{
   if(!m_trade.PositionModify(ticket, new_sl, m_position.TakeProfit()))
   {
      if(m_trade.ResultRetcode() != 10006 && m_trade.ResultRetcode() != 10025)
         Print("Modificação de SL falhou: ", m_trade.ResultRetcodeDescription(), " em ", m_symbol_name);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Is Stop Level OK                                                 |
//+------------------------------------------------------------------+
bool CUniversalTrailing::IsStopLevelOk(double price, double sl, ENUM_POSITION_TYPE type)
{
   int stop_level = (int)SymbolInfoInteger(m_symbol_name, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze_level = (int)SymbolInfoInteger(m_symbol_name, SYMBOL_TRADE_FREEZE_LEVEL);
   double min_dist = (stop_level > freeze_level ? stop_level : freeze_level) * m_symbol.Point();
   min_dist += m_symbol.Point();

   if(type == POSITION_TYPE_BUY) return (price - sl > min_dist);
   else return (sl - price > min_dist);
}
