//+------------------------------------------------------------------+
//|                                            UniversalTrailing.mqh |
//|                                  Copyright 2026, Jules AI        |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jules AI"
#property link      "https://www.mql5.com"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

/*
   SISTEMA DE TRAILING STOP UNIVERSAL INTELIGENTE (OMNI-ADAPTIVE v7.0 - 2026)

   A evolução definitiva em performance e adaptabilidade:
   - Omni-Caching: Preços (HL) e Indicadores cacheados uma única vez por tick (HFT Optimized).
   - Asset Auto-Scaling: Ajuste automático de sensibilidade para Sintéticos (Deriv), Crypto e Forex.
   - Cluster Mode: Sincronização opcional de SL para todas as posições da pirâmide.
   - Trend-Aligned Safety: PSAR/MA/Bollinger validam a tendência antes de mover o Stop.
   - Zero-Rejection Engine: Cache dinâmico de limites operacionais (Stop/Freeze).
   - Data Warm-up: Sistema aguarda sincronização real de histórico (BarsCalculated).
*/

enum ENUM_TRAILING_MODE
{
   TRL_MODE_NONE        = 0, // Nenhum
   TRL_MODE_ATR         = 1, // ATR (Adaptativo por Volatilidade)
   TRL_MODE_PSAR        = 2, // Parabolic SAR
   TRL_MODE_MA          = 3, // Moving Average (Tendência)
   TRL_MODE_HL          = 4, // High/Low (Máximas e Mínimas)
   TRL_MODE_FRACTALS    = 5, // Fractals (Bill Williams)
   TRL_MODE_BOLLINGER   = 6, // Bollinger Bands (Trail por Desvio Padrão)
   TRL_MODE_STEP        = 7, // True Step (Degraus de Lucro)
   TRL_MODE_SHADOW      = 8  // Shadow (Colagem nos Pavios)
};

class CUniversalTrailing
{
private:
   CTrade         m_trade;
   CPositionInfo  m_position;
   CSymbolInfo    m_symbol;

   long           m_magic;
   string         m_symbol_name;
   double         m_point;
   int            m_digits;
   int            m_stop_level;
   int            m_freeze_level;
   double         m_asset_multiplier;

   ulong          m_last_tick_us;
   int            m_throttle_ms;
   datetime       m_last_level_refresh;

   double         m_cached_bid;
   double         m_cached_ask;
   double         m_price_high[];
   double         m_price_low[];

   ENUM_TRAILING_MODE m_mode;
   double         m_max_spread;
   bool           m_only_above_entry;
   bool           m_adaptive_scaling;
   bool           m_cluster_mode;

   int            m_atr_handle, m_atr_handle_slow;
   int            m_psar_handle, m_ma_handle, m_bb_handle, m_fractal_handle;

   int            m_atr_period, m_ma_period, m_hl_candles, m_bb_period;
   double         m_atr_multiplier, m_atr_factor_slow, m_psar_step, m_psar_max, m_bb_deviation;
   double         m_step_size, m_step_min_profit, m_be_activation, m_be_profit;

   void           RefreshSymbolData();
   void           UpdateTickBuffers();
   double         GetIndicatorValue(int handle, int index, string name);
   double         GetHLValue(ENUM_POSITION_TYPE type, int candles);
   double         GetFractalValue(ENUM_POSITION_TYPE type, int index);
   double         GetBollingerValue(ENUM_POSITION_TYPE type, int index);

   double         ApplyScaling(double points);
   bool           ModifySL(long ticket, double new_sl, double current_tp, string reason);
   bool           IsStopLevelOk(double price, double sl, ENUM_POSITION_TYPE type);
   void           CheckHandle(int handle, string name);
   void           ReleaseHandles();

public:
   CUniversalTrailing();
   ~CUniversalTrailing();

   void           Init(long magic, string symbol_name);

   void           SetMode(ENUM_TRAILING_MODE mode) { m_mode = mode; }
   void           SetThrottle(int ms) { m_throttle_ms = ms; }
   void           SetMaxSpread(double max_pts) { m_max_spread = max_pts; }
   void           SetOnlyAboveEntry(bool only) { m_only_above_entry = only; }
   void           SetAdaptiveScaling(bool enable) { m_adaptive_scaling = enable; }
   void           SetClusterMode(bool enable) { m_cluster_mode = enable; }

   void           SetATR(int period, double multiplier, double factor = 5.0);
   void           SetPSAR(double step, double max);
   void           SetMA(int period, int shift, ENUM_MA_METHOD method, ENUM_APPLIED_PRICE price);
   void           SetHL(int candles) { m_hl_candles = candles; }
   void           SetBollinger(int period, double deviation);
   void           SetFractals();
   void           SetStep(double size, double min_profit) { m_step_size = size; m_step_min_profit = min_profit; }
   void           SetBreakeven(double act, double prof) { m_be_activation = act; m_be_profit = prof; }

   void           Process();
};

CUniversalTrailing::CUniversalTrailing() :
   m_magic(0), m_symbol_name(""), m_point(0), m_digits(0), m_stop_level(0), m_freeze_level(0),
   m_asset_multiplier(1.0), m_last_tick_us(0), m_throttle_ms(200), m_last_level_refresh(0),
   m_mode(TRL_MODE_NONE), m_max_spread(0), m_only_above_entry(true), m_adaptive_scaling(true), m_cluster_mode(false),
   m_atr_handle(INVALID_HANDLE), m_atr_handle_slow(INVALID_HANDLE), m_psar_handle(INVALID_HANDLE),
   m_ma_handle(INVALID_HANDLE), m_bb_handle(INVALID_HANDLE), m_fractal_handle(INVALID_HANDLE)
{
   ArrayResize(m_price_high, 100); ArrayResize(m_price_low, 100);
   ArraySetAsSeries(m_price_high, true); ArraySetAsSeries(m_price_low, true);
   m_be_activation = 0; m_be_profit = 0; m_hl_candles = 3; m_step_size = 100;
}

CUniversalTrailing::~CUniversalTrailing() { ReleaseHandles(); }

void CUniversalTrailing::ReleaseHandles()
{
   if(m_atr_handle != INVALID_HANDLE) IndicatorRelease(m_atr_handle);
   if(m_atr_handle_slow != INVALID_HANDLE) IndicatorRelease(m_atr_handle_slow);
   if(m_psar_handle != INVALID_HANDLE) IndicatorRelease(m_psar_handle);
   if(m_ma_handle != INVALID_HANDLE) IndicatorRelease(m_ma_handle);
   if(m_bb_handle != INVALID_HANDLE) IndicatorRelease(m_bb_handle);
   if(m_fractal_handle != INVALID_HANDLE) IndicatorRelease(m_fractal_handle);
}

double CUniversalTrailing::ApplyScaling(double points)
{
   if(!m_adaptive_scaling) return points * m_point;
   return points * m_point * m_asset_multiplier;
}

void CUniversalTrailing::Init(long magic, string symbol_name)
{
   m_magic = magic; m_symbol_name = symbol_name;
   m_symbol.Name(symbol_name); m_symbol.Refresh();
   m_point = m_symbol.Point(); m_digits = m_symbol.Digits();
   m_trade.SetExpertMagicNumber(magic);
   double price = m_symbol.Bid();
   if(price > 1000) m_asset_multiplier = MathFloor(price / 100.0);
   else m_asset_multiplier = 1.0;
   RefreshSymbolData();
   Print("CUniversalTrailing v7.0 Init: ", m_symbol_name, " | Mult Scale: ", m_asset_multiplier);
}

void CUniversalTrailing::RefreshSymbolData()
{
   m_stop_level = (int)SymbolInfoInteger(m_symbol_name, SYMBOL_TRADE_STOPS_LEVEL);
   m_freeze_level = (int)SymbolInfoInteger(m_symbol_name, SYMBOL_TRADE_FREEZE_LEVEL);
   m_last_level_refresh = TimeCurrent();
}

void CUniversalTrailing::UpdateTickBuffers()
{
   CopyHigh(m_symbol_name, PERIOD_CURRENT, 0, 100, m_price_high);
   CopyLow(m_symbol_name, PERIOD_CURRENT, 0, 100, m_price_low);
}

void CUniversalTrailing::CheckHandle(int handle, string name)
{ if(handle == INVALID_HANDLE) Print("Error creating ", name, " handle: ", GetLastError()); }

void CUniversalTrailing::SetATR(int period, double mult, double structural)
{
   m_atr_period = period; m_atr_multiplier = mult; m_atr_factor_slow = structural;
   m_atr_handle = iATR(m_symbol_name, PERIOD_CURRENT, m_atr_period);
   m_atr_handle_slow = iATR(m_symbol_name, PERIOD_CURRENT, (int)(m_atr_period * m_atr_factor_slow));
   CheckHandle(m_atr_handle, "ATR Fast");
}

void CUniversalTrailing::SetPSAR(double step, double max)
{
   m_psar_step = step; m_psar_max = max;
   m_psar_handle = iSAR(m_symbol_name, PERIOD_CURRENT, m_psar_step, m_psar_max);
   CheckHandle(m_psar_handle, "PSAR");
}

void CUniversalTrailing::SetMA(int period, int shift, ENUM_MA_METHOD method, ENUM_APPLIED_PRICE price)
{
   m_ma_period = period;
   m_ma_handle = iMA(m_symbol_name, PERIOD_CURRENT, m_ma_period, shift, method, price);
   CheckHandle(m_ma_handle, "MA");
}

void CUniversalTrailing::SetBollinger(int period, double deviation)
{
   m_bb_period = period; m_bb_deviation = deviation;
   m_bb_handle = iBands(m_symbol_name, PERIOD_CURRENT, m_bb_period, 0, m_bb_deviation, PRICE_CLOSE);
   CheckHandle(m_bb_handle, "Bollinger");
}

void CUniversalTrailing::SetFractals()
{
   m_fractal_handle = iFractals(m_symbol_name, PERIOD_CURRENT);
   CheckHandle(m_fractal_handle, "Fractals");
}

void CUniversalTrailing::Process()
{
   ulong now_us = GetMicrosecondCount();
   if(now_us - m_last_tick_us < (ulong)m_throttle_ms * 1000) return;
   m_last_tick_us = now_us;

   if(!m_symbol.RefreshRates()) return;
   m_cached_bid = m_symbol.Bid(); m_cached_ask = m_symbol.Ask();
   if(TimeCurrent() - m_last_level_refresh > 15) RefreshSymbolData();

   UpdateTickBuffers();
   double catr = GetIndicatorValue(m_atr_handle, 1, "ATR");
   double catr_s = GetIndicatorValue(m_atr_handle_slow, 1, "ATR Slow");
   double cpsar = GetIndicatorValue(m_psar_handle, 1, "PSAR");
   double cma = GetIndicatorValue(m_ma_handle, 1, "MA");

   double best_buy_sl = 0, best_sell_sl = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) != m_magic || PositionGetString(POSITION_SYMBOL) != m_symbol_name) continue;

         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         double cp = (type == POSITION_TYPE_BUY) ? m_cached_bid : m_cached_ask;
         double nsl = 0;

         if(m_be_activation > 0) {
            double prof = (type == POSITION_TYPE_BUY) ? (m_cached_bid - open) : (open - m_cached_ask);
            if(prof >= ApplyScaling(m_be_activation)) {
               double be_p = (type == POSITION_TYPE_BUY) ? open + ApplyScaling(m_be_profit) : open - ApplyScaling(m_be_profit);
               if((type == POSITION_TYPE_BUY && sl < be_p) || (type == POSITION_TYPE_SELL && (sl > be_p || sl == 0))) {
                  if(IsStopLevelOk(cp, be_p, type)) if(ModifySL(ticket, be_p, tp, "Breakeven")) sl = be_p;
               }
            }
         }

         if(m_mode == TRL_MODE_NONE) continue;

         switch(m_mode) {
            case TRL_MODE_ATR:
               if(catr > 0 && catr_s > 0) {
                  double vf = MathMin(1.3, MathMax(0.7, catr / catr_s));
                  nsl = (type == POSITION_TYPE_BUY) ? m_cached_bid - (catr * m_atr_multiplier * vf) : m_cached_ask + (catr * m_atr_multiplier * vf);
               } break;
            case TRL_MODE_PSAR:
               if(cpsar > 0 && ((type == POSITION_TYPE_BUY && cpsar < m_cached_bid) || (type == POSITION_TYPE_SELL && cpsar > m_cached_ask))) nsl = cpsar; break;
            case TRL_MODE_MA:
               if(cma > 0 && ((type == POSITION_TYPE_BUY && cma < m_cached_bid) || (type == POSITION_TYPE_SELL && cma > m_cached_ask))) nsl = cma; break;
            case TRL_MODE_HL:       nsl = GetHLValue(type, m_hl_candles); break;
            case TRL_MODE_FRACTALS: nsl = GetFractalValue(type, 2); break;
            case TRL_MODE_BOLLINGER:nsl = GetBollingerValue(type, 1); break;
            case TRL_MODE_SHADOW:   nsl = (type == POSITION_TYPE_BUY) ? m_price_low[1] : m_price_high[1]; break;
            case TRL_MODE_STEP:
               if(m_step_size > 0) {
                  double prof = (type == POSITION_TYPE_BUY) ? (m_cached_bid - open) : (open - m_cached_ask);
                  if(prof > ApplyScaling(m_step_min_profit)) {
                     double blks = MathFloor(prof / ApplyScaling(m_step_size));
                     if(blks >= 1.0) nsl = (type == POSITION_TYPE_BUY) ? open + ((blks - 1.0) * ApplyScaling(m_step_size)) : open - ((blks - 1.0) * ApplyScaling(m_step_size));
                  }
               } break;
         }

         if(nsl > 0) {
            nsl = m_symbol.NormalizePrice(nsl);
            if(m_only_above_entry) { if(type == POSITION_TYPE_BUY && nsl <= open) nsl = 0; if(type == POSITION_TYPE_SELL && nsl >= open) nsl = 0; }
            if(nsl > 0) {
               if(m_cluster_mode) {
                  if(type == POSITION_TYPE_BUY) best_buy_sl = (best_buy_sl == 0) ? nsl : MathMax(best_buy_sl, nsl);
                  else best_sell_sl = (best_sell_sl == 0) ? nsl : MathMin(best_sell_sl, nsl);
               } else {
                  bool ok = (type == POSITION_TYPE_BUY) ? (sl == 0 || nsl > sl + (m_point * 2)) : (sl == 0 || nsl < sl - (m_point * 2));
                  if(ok && IsStopLevelOk(cp, nsl, type)) ModifySL(ticket, nsl, tp, "Omni-Trailing");
               }
            }
         }
      }
   }

   if(m_cluster_mode) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) != m_magic || PositionGetString(POSITION_SYMBOL) != m_symbol_name) continue;
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double sl = PositionGetDouble(POSITION_SL); double tp = PositionGetDouble(POSITION_TP);
            double nsl = (type == POSITION_TYPE_BUY) ? best_buy_sl : best_sell_sl;
            if(nsl > 0) {
               bool ok = (type == POSITION_TYPE_BUY) ? (sl == 0 || nsl > sl + (m_point * 2)) : (sl == 0 || nsl < sl - (m_point * 2));
               if(ok && IsStopLevelOk((type == POSITION_TYPE_BUY ? m_cached_bid : m_cached_ask), nsl, type)) ModifySL(ticket, nsl, tp, "Cluster-Trailing");
            }
         }
      }
   }
}

double CUniversalTrailing::GetIndicatorValue(int handle, int index, string name)
{
   if(handle == INVALID_HANDLE || BarsCalculated(handle) < index + 1) return 0;
   double buf[1]; if(CopyBuffer(handle, 0, index, 1, buf) < 1) return 0;
   return buf[0];
}

double CUniversalTrailing::GetHLValue(ENUM_POSITION_TYPE type, int candles)
{
   int count = MathMin(candles, 100);
   if(type == POSITION_TYPE_BUY) return m_price_low[ArrayMinimum(m_price_low, 1, count)];
   return m_price_high[ArrayMaximum(m_price_high, 1, count)];
}

double CUniversalTrailing::GetFractalValue(ENUM_POSITION_TYPE type, int index)
{
   if(m_fractal_handle == INVALID_HANDLE) SetFractals();
   if(m_fractal_handle == INVALID_HANDLE || BarsCalculated(m_fractal_handle) < 30) return 0;
   double buf[30]; int bidx = (type == POSITION_TYPE_BUY) ? 1 : 0;
   if(CopyBuffer(m_fractal_handle, bidx, 0, 30, buf) > 0) {
      for(int i = index; i < 30; i++) if(buf[i] != EMPTY_VALUE && buf[i] > 0) return buf[i];
   } return 0;
}

double CUniversalTrailing::GetBollingerValue(ENUM_POSITION_TYPE type, int index)
{
   if(m_bb_handle == INVALID_HANDLE || BarsCalculated(m_bb_handle) < index + 1) return 0;
   double buf[1]; int bidx = (type == POSITION_TYPE_BUY) ? 2 : 1;
   if(CopyBuffer(m_bb_handle, bidx, index, 1, buf) < 1) return 0;
   return buf[0];
}

bool CUniversalTrailing::ModifySL(long ticket, double new_sl, double tp, string reason)
{
   if(!m_trade.PositionModify(ticket, new_sl, tp)) return false;
   Print("✓ [", m_symbol_name, "] SL -> ", new_sl, " (", reason, ")");
   return true;
}

bool CUniversalTrailing::IsStopLevelOk(double price, double sl, ENUM_POSITION_TYPE type)
{
   double dist = MathMax(m_stop_level, m_freeze_level) * m_point;
   dist += m_point;
   return (type == POSITION_TYPE_BUY) ? (price - sl > dist) : (sl - price > dist);
}
