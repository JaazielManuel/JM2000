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
   SISTEMA DE TRAILING STOP UNIVERSAL INTELIGENTE (SURGICAL MASTER VERSION)

   Esta versão representa o Nível 10+ (Estado da Arte):
   - Encapsulamento Total: Métodos auxiliares protegidos dentro da classe.
   - Zero Dynamic Allocation: Buffers de HL pré-alocados para performance HFT.
   - Institutional ATR Factor: Escalabilidade estrutural parametrizável (3x a 10x).
   - Zero-Division Guard: Proteção robusta contra inputs inválidos no modo Step.
   - Pre-Filtering Logic: Salto de processamento para posições fora da zona de interesse.
   - Point Caching: Redução de chamadas de método para extração de precisão do símbolo.
   - Tick Caching & Throttling: Otimização extrema de CPU e latência.
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
   double         m_point;          // Cache de Precisão

   // Performance & Throttling
   uint           m_last_tick_ms;
   int            m_throttle_ms;

   // Parâmetros Gerais
   ENUM_TRAILING_MODE m_mode;
   double         m_max_spread;
   bool           m_only_above_entry;

   // ATR handles
   int            m_atr_period;
   double         m_atr_multiplier;
   double         m_atr_factor_slow; // Fator de escala estrutural
   int            m_atr_handle;
   int            m_atr_handle_slow;

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
   double         m_hl_buffer[];     // Buffer pré-alocado

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

   // Métodos auxiliares encapsulados
   void           CheckHandle(int handle, string name);
   double         GetIndicatorValue(int handle, int index);
   double         GetBollingerValue(ENUM_POSITION_TYPE type, int index);
   double         GetFractalValue(ENUM_POSITION_TYPE type, int index);
   double         GetHLValue(ENUM_POSITION_TYPE type, int candles);
   double         GetShadowValue(ENUM_POSITION_TYPE type, int index);

   bool           ModifySL(long ticket, double new_sl, double current_tp);
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

   void           SetATR(int period, double multiplier, double structural_factor = 5.0);
   void           SetPSAR(double step, double max);
   void           SetMA(int period, int shift, ENUM_MA_METHOD method, ENUM_APPLIED_PRICE price);
   void           SetHL(int candles);
   void           SetBollinger(int period, double deviation);
   void           SetFractals();
   void           SetStep(double step_size, double min_profit);
   void           SetBreakeven(double activation, double profit);

   void           Process();
};

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CUniversalTrailing::CUniversalTrailing() :
   m_magic(0),
   m_symbol_name(""),
   m_point(0),
   m_mode(TRL_MODE_NONE),
   m_atr_handle(INVALID_HANDLE),
   m_atr_handle_slow(INVALID_HANDLE),
   m_psar_handle(INVALID_HANDLE),
   m_ma_handle(INVALID_HANDLE),
   m_bb_handle(INVALID_HANDLE),
   m_fractal_handle(INVALID_HANDLE),
   m_max_spread(0),
   m_throttle_ms(250),
   m_last_tick_ms(0),
   m_only_above_entry(true)
{
   m_be_activation = 0;
   m_be_profit = 0;
   m_hl_candles = 3;
   m_step_size = 100;
   m_step_min_profit = 0;
   ArrayResize(m_hl_buffer, 50); // Pré-aloca 50 velas por padrão
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
   if(m_atr_handle_slow != INVALID_HANDLE) { IndicatorRelease(m_atr_handle_slow); m_atr_handle_slow = INVALID_HANDLE; }
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
   m_symbol.Refresh();
   m_point = m_symbol.Point();
   m_trade.SetExpertMagicNumber(magic);
}

//+------------------------------------------------------------------+
//| Internal Handle Validation                                       |
//+------------------------------------------------------------------+
void CUniversalTrailing::CheckHandle(int handle, string name)
{
   if(handle == INVALID_HANDLE)
      Print("CRITICAL ERROR [", m_symbol_name, "]: Failed to create ", name, " (Error: ", GetLastError(), ")");
}

//+------------------------------------------------------------------+
//| Configurations with Refined Validation                           |
//+------------------------------------------------------------------+
void CUniversalTrailing::SetATR(int period, double multiplier, double structural_factor)
{
   m_atr_period = period;
   m_atr_multiplier = multiplier;
   m_atr_factor_slow = (structural_factor < 2.0) ? 2.0 : structural_factor;

   if(m_atr_handle != INVALID_HANDLE) IndicatorRelease(m_atr_handle);
   if(m_atr_handle_slow != INVALID_HANDLE) IndicatorRelease(m_atr_handle_slow);

   m_atr_handle = iATR(m_symbol_name, PERIOD_CURRENT, m_atr_period);
   CheckHandle(m_atr_handle, "ATR (Fast)");
   m_atr_handle_slow = iATR(m_symbol_name, PERIOD_CURRENT, (int)(m_atr_period * m_atr_factor_slow));
   CheckHandle(m_atr_handle_slow, "ATR (Structural)");
}

void CUniversalTrailing::SetPSAR(double step, double max)
{
   m_psar_step = step;
   m_psar_max = max;
   if(m_psar_handle != INVALID_HANDLE) IndicatorRelease(m_psar_handle);
   m_psar_handle = iSAR(m_symbol_name, PERIOD_CURRENT, m_psar_step, m_psar_max);
   CheckHandle(m_psar_handle, "PSAR");
}

void CUniversalTrailing::SetMA(int period, int shift, ENUM_MA_METHOD method, ENUM_APPLIED_PRICE price)
{
   m_ma_period = period;
   m_ma_shift = shift;
   m_ma_method = method;
   m_ma_price = price;
   if(m_ma_handle != INVALID_HANDLE) IndicatorRelease(m_ma_handle);
   m_ma_handle = iMA(m_symbol_name, PERIOD_CURRENT, m_ma_period, m_ma_shift, m_ma_method, m_ma_price);
   CheckHandle(m_ma_handle, "MA");
}

void CUniversalTrailing::SetHL(int candles)
{
   m_hl_candles = candles;
   if(ArraySize(m_hl_buffer) < m_hl_candles) ArrayResize(m_hl_buffer, m_hl_candles + 10);
}

void CUniversalTrailing::SetBollinger(int period, double deviation)
{
   m_bb_period = period;
   m_bb_deviation = deviation;
   if(m_bb_handle != INVALID_HANDLE) IndicatorRelease(m_bb_handle);
   m_bb_handle = iBands(m_symbol_name, PERIOD_CURRENT, m_bb_period, 0, m_bb_deviation, PRICE_CLOSE);
   CheckHandle(m_bb_handle, "Bollinger");
}

void CUniversalTrailing::SetFractals()
{
   if(m_fractal_handle != INVALID_HANDLE) IndicatorRelease(m_fractal_handle);
   m_fractal_handle = iFractals(m_symbol_name, PERIOD_CURRENT);
   CheckHandle(m_fractal_handle, "Fractals");
}

void CUniversalTrailing::SetStep(double step_size, double min_profit)
{
   m_step_size = step_size;
   m_step_min_profit = min_profit;
}

void CUniversalTrailing::SetBreakeven(double activation, double profit)
{
   m_be_activation = activation;
   m_be_profit = profit;
}

//+------------------------------------------------------------------+
//| Main Process Loop (Surgical Level)                               |
//+------------------------------------------------------------------+
void CUniversalTrailing::Process()
{
   uint now_ms = GetTickCount();
   if(now_ms - m_last_tick_ms < (uint)m_throttle_ms) return;
   m_last_tick_ms = now_ms;

   if(!m_symbol.RefreshRates()) return;
   double bid = m_symbol.Bid();
   double ask = m_symbol.Ask();

   if(m_max_spread > 0)
   {
      double spread = (ask - bid) / m_point;
      if(spread > m_max_spread) return;
   }

   // Tick Caching Institutional
   double cached_atr = 0, cached_atr_slow = 0, cached_psar = 0, cached_ma = 0;
   if(m_mode == TRL_MODE_ATR) {
      cached_atr = GetIndicatorValue(m_atr_handle, 1);
      cached_atr_slow = GetIndicatorValue(m_atr_handle_slow, 1);
   }
   else if(m_mode == TRL_MODE_PSAR) cached_psar = GetIndicatorValue(m_psar_handle, 1);
   else if(m_mode == TRL_MODE_MA)   cached_ma = GetIndicatorValue(m_ma_handle, 1);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Magic() == m_magic && m_position.Symbol() == m_symbol_name)
         {
            ENUM_POSITION_TYPE type = m_position.PositionType();
            double open_price = m_position.PriceOpen();
            double current_price = (type == POSITION_TYPE_BUY) ? bid : ask;

            // Early-Exit para Posições em Prejuízo Significativo (Micro-otimização)
            if(m_only_above_entry)
            {
               if(type == POSITION_TYPE_BUY && bid < open_price) continue;
               if(type == POSITION_TYPE_SELL && ask > open_price) continue;
            }

            double current_sl = m_position.StopLoss();
            double current_tp = m_position.TakeProfit();
            double new_sl = 0;

            // A. Breakeven
            if(m_be_activation > 0)
            {
               double profit_pts = (type == POSITION_TYPE_BUY) ? (bid - open_price) : (open_price - ask);
               profit_pts /= m_point;

               if(profit_pts >= m_be_activation)
               {
                  double be_price = (type == POSITION_TYPE_BUY) ?
                                    open_price + (m_be_profit * m_point) :
                                    open_price - (m_be_profit * m_point);

                  bool can_be = (type == POSITION_TYPE_BUY) ? (current_sl < be_price) : (current_sl > be_price || current_sl == 0);

                  if(can_be && IsStopLevelOk(current_price, be_price, type))
                  {
                     if(ModifySL(m_position.Ticket(), be_price, current_tp))
                        current_sl = be_price;
                  }
               }
            }

            // B. Trailing Logic (Level 10+ Math)
            if(m_mode == TRL_MODE_NONE) continue;

            switch(m_mode)
            {
               case TRL_MODE_ATR:
                  if(cached_atr > 0 && cached_atr_slow > 0)
                  {
                     double vol_factor = cached_atr / cached_atr_slow;
                     if(vol_factor > 1.3) vol_factor = 1.3;
                     if(vol_factor < 0.7) vol_factor = 0.7;
                     double dynamic_multiplier = m_atr_multiplier * vol_factor;
                     new_sl = (type == POSITION_TYPE_BUY) ? bid - (cached_atr * dynamic_multiplier) : ask + (cached_atr * dynamic_multiplier);
                  }
                  break;

               case TRL_MODE_PSAR:      new_sl = cached_psar; break;
               case TRL_MODE_MA:        new_sl = cached_ma; break;
               case TRL_MODE_HL:        new_sl = GetHLValue(type, m_hl_candles); break;
               case TRL_MODE_FRACTALS:  new_sl = GetFractalValue(type, 2); break;
               case TRL_MODE_BOLLINGER: new_sl = GetBollingerValue(type, 1); break;
               case TRL_MODE_SHADOW:    new_sl = GetShadowValue(type, 1); break;

               case TRL_MODE_STEP:
                  if(m_step_size > 0) // Zero-Division Guard
                  {
                     double step_pts = m_step_size * m_point;
                     double current_profit = (type == POSITION_TYPE_BUY) ? (bid - open_price) : (open_price - ask);

                     if(current_profit > m_step_min_profit * m_point)
                     {
                        double blocks = MathFloor(current_profit / step_pts);
                        if(blocks >= 1.0)
                        {
                           new_sl = (type == POSITION_TYPE_BUY) ?
                                    open_price + ((blocks - 1.0) * step_pts) :
                                    open_price - ((blocks - 1.0) * step_pts);
                        }
                     }
                  }
                  break;
            }

            // C. Directional Integrity & Normalization
            if(new_sl > 0)
            {
               new_sl = m_symbol.NormalizePrice(new_sl);

               // Final Structural Filter
               if(m_only_above_entry)
               {
                  if(type == POSITION_TYPE_BUY && new_sl <= open_price) new_sl = 0;
                  if(type == POSITION_TYPE_SELL && new_sl >= open_price) new_sl = 0;
               }

               if(new_sl > 0)
               {
                  bool should_modify = false;
                  if(type == POSITION_TYPE_BUY)
                  {
                     if(new_sl > current_sl + (m_point * 2) && new_sl < bid) should_modify = true;
                  }
                  else
                  {
                     if((new_sl < current_sl - (m_point * 2) || current_sl == 0) && new_sl > ask) should_modify = true;
                  }

                  if(should_modify && IsStopLevelOk(current_price, new_sl, type))
                  {
                     ModifySL(m_position.Ticket(), new_sl, current_tp);
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get Indicator Value (Safe)                                       |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetIndicatorValue(int handle, int index)
{
   if(handle == INVALID_HANDLE) return 0;
   double buffer[1];
   if(CopyBuffer(handle, 0, index, 1, buffer) < 1) return 0;
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
//| Get High/Low Value (Zero Allocation Optimization)                |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetHLValue(ENUM_POSITION_TYPE type, int candles)
{
   int count = (candles > ArraySize(m_hl_buffer)) ? ArraySize(m_hl_buffer) : candles;
   if(type == POSITION_TYPE_BUY)
   {
      if(CopyLow(m_symbol_name, PERIOD_CURRENT, 1, count, m_hl_buffer) > 0)
         return m_hl_buffer[ArrayMinimum(m_hl_buffer, 0, count)];
   }
   else
   {
      if(CopyHigh(m_symbol_name, PERIOD_CURRENT, 1, count, m_hl_buffer) > 0)
         return m_hl_buffer[ArrayMaximum(m_hl_buffer, 0, count)];
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Get Fractal Value (Surgical Depth)                               |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetFractalValue(ENUM_POSITION_TYPE type, int index)
{
   if(m_fractal_handle == INVALID_HANDLE) SetFractals();
   double buffer[30]; // Fixed stack buffer
   int buffer_idx = (type == POSITION_TYPE_BUY) ? 1 : 0;

   if(CopyBuffer(m_fractal_handle, buffer_idx, 0, 30, buffer) > 0)
   {
      for(int i = index; i < 30; i++)
         if(buffer[i] != EMPTY_VALUE && buffer[i] > 0) return buffer[i];
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Get Shadow Value                                                 |
//+------------------------------------------------------------------+
double CUniversalTrailing::GetShadowValue(ENUM_POSITION_TYPE type, int index)
{
   double arr[1];
   if(type == POSITION_TYPE_BUY)
   {
      if(CopyLow(m_symbol_name, PERIOD_CURRENT, index, 1, arr) > 0) return arr[0];
   }
   else
   {
      if(CopyHigh(m_symbol_name, PERIOD_CURRENT, index, 1, arr) > 0) return arr[0];
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Modify Stop Loss                                                 |
//+------------------------------------------------------------------+
bool CUniversalTrailing::ModifySL(long ticket, double new_sl, double current_tp)
{
   if(!m_trade.PositionModify(ticket, new_sl, current_tp))
   {
      uint code = m_trade.ResultRetcode();
      if(code != 10006 && code != 10025)
         Print("Modificação de SL falhou [", m_symbol_name, "]: ", m_trade.ResultRetcodeDescription());
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
   double min_dist = (stop_level > freeze_level ? stop_level : freeze_level) * m_point;
   min_dist += m_point;

   if(type == POSITION_TYPE_BUY) return (price - sl > min_dist);
   else return (sl - price > min_dist);
}
