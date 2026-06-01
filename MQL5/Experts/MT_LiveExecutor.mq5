//=========================  MT5-LIVE-EXECUTOR  =========================
// Baseado no MT5-KNOWLEDGE-CORE
//========================================================================

#property copyright "MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\DealInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

// --- Definicoes ---
#define EA_MAGIC 123456
#define LOG_FILE "MT_LiveExecutor_Log.txt"
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define PROMPT_FILE "prompt.txt"
#define NEWS_VETO_FILE "news_veto.txt"
#define CALENDAR_FILE "calendar.txt"

// --- Enums ---
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

// --- Structs ---
struct Rule {
    bool     active;
    int      type;      // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: Relative
    int      intent;    // BUY or SELL
    ENUM_TIMEFRAMES tf;
    int      p1, p2, p3;
    double   d1, d2;
    string   s1;
    int      handle1, handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        active = false; type = 0; intent = 0; tf = PERIOD_CURRENT;
        p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
        handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
    }
};

// --- Globals ---
Rule     rules[20];
int      nRules = 0;
CTrade   trade;
CPositionInfo pos;
CSymbolInfo symbol;
CAccountInfo account;

string   p_prompt = "";
double   p_riskPercent = 1.0;
int      p_stopLoss = 300; // pontos
int      p_takeProfit = 500; // pontos
int      p_maxTrades = 3;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
string   p_startTime = "00:00";
bool     p_martingale = false;
int      p_newsVeto = 20; // minutos
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime last_bar = 0;
datetime last_csv = 0;
datetime last_ai = 0;

// --- Prototypes ---
void InterpretaPrompt(string prompt);
void ResetStrategy();
Signal AvaliaTudo();
Signal AvaliaRegra(Rule &r);
void EnviaOrdem(Signal s);
double CalculaLote();
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string txt);
void GravaCSV();
void AIOptimizer();
double GetBufferValue(int handle, int buffer, int shift);
bool IsTimeAllowed();
void CalculaStats();

// --- NLP Parser ---
void InterpretaPrompt(string prompt) {
    ResetStrategy();
    p_prompt = prompt;
    string work = prompt;
    StringToLower(work);

    // Pre-processamento: substituir ' e ' por '.' para facilitar split
    StringReplace(work, " e ", ".");

    string segments[];
    int n = StringSplit(work, '.', segments);

    int currentIntent = 0;

    for(int i=0; i<n; i++) {
        string seg = segments[i];
        StringTrimLeft(seg);
        StringTrimRight(seg);

        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

        // Parametros globais
        int cursor = 0;
        int findIdx = -1;

        findIdx = StringFind(seg, "risco de");
        if(findIdx >= 0) { cursor = findIdx + 8; p_riskPercent = ExtraiNumero(seg, cursor); }

        findIdx = StringFind(seg, "stop de");
        if(findIdx >= 0) { cursor = findIdx + 7; p_stopLoss = (int)ExtraiNumero(seg, cursor); }

        findIdx = StringFind(seg, "take de");
        if(findIdx >= 0) { cursor = findIdx + 7; p_takeProfit = (int)ExtraiNumero(seg, cursor); }

        findIdx = StringFind(seg, "máximo");
        if(findIdx >= 0) { cursor = findIdx + 6; p_maxTrades = (int)ExtraiNumero(seg, cursor); }

        findIdx = StringFind(seg, "atingir");
        if(findIdx >= 0) { cursor = findIdx + 7; p_beStart = (int)ExtraiNumero(seg, cursor); }

        findIdx = StringFind(seg, "entrada +");
        if(findIdx >= 0) { cursor = findIdx + 9; p_bePlus = (int)ExtraiNumero(seg, cursor); }

        findIdx = StringFind(seg, "trailing");
        if(findIdx >= 0) {
            cursor = findIdx + 8;
            p_trailingStop = (int)ExtraiNumero(seg, cursor);
            p_trailingStep = 10; // default
        }
        findIdx = StringFind(seg, "depois das");
        if(findIdx < 0) findIdx = StringFind(seg, "início");
        if(findIdx < 0) findIdx = StringFind(seg, "começar");
        if(findIdx >= 0) {
            cursor = findIdx + 10;
            int h = (int)ExtraiNumero(seg, cursor);
            int m = 0;
            p_startTime = StringFormat("%02d:%02d", h, m);
        }

        if(StringFind(seg, "martingale") >= 0) p_martingale = true;

        findIdx = StringFind(seg, "notícias");
        if(findIdx >= 0) { cursor = findIdx + 8; p_newsVeto = (int)ExtraiNumero(seg, cursor); }
        if(p_newsVeto == 0) p_newsVeto = 20;

        // Frequencia
        if(StringFind(seg, "cada") >= 0) {
            int f = (int)ExtraiNumero(seg, cursor);
            string tf_str = "";
            if(StringFind(seg, "minuto") >= 0) tf_str = "m" + (string)f;
            p_frequency = PeriodoTexto(tf_str);
        }

        // Regras de Indicadores
        if(currentIntent != 0) {
            AddRule(seg, currentIntent);
        }
    }
    GravaLog("Prompt interpretado: " + prompt);
}

void AddRule(string txt, int intent) {
    if(nRules >= 20) return;

    Rule r;
    r.Reset();
    r.intent = intent;
    r.tf = p_frequency;

    int cursor = 0;

    // Média
    int findIdx = StringFind(txt, "média");
    if(findIdx >= 0) {
        cursor = findIdx + 5;
        r.type = 1;
        r.active = true;
        r.p1 = (int)ExtraiNumero(txt, cursor);
        if(r.p1 == 0) r.p1 = 20;
        r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) {
            rules[nRules] = r;
            nRules++;
        }
    }

    // RSI
    findIdx = StringFind(txt, "rsi");
    if(findIdx >= 0) {
        cursor = findIdx + 3;
        r.Reset();
        r.intent = intent;
        r.tf = p_frequency;
        r.type = 2;
        r.active = true;
        double val1 = ExtraiNumero(txt, cursor);
        double val2 = ExtraiNumero(txt, cursor);

        if(val2 == 0) { // So um numero encontrado
            if(val1 >= 40) { r.p1 = 14; r.d1 = val1; }
            else { r.p1 = (int)val1; r.d1 = (intent == BUY) ? 30 : 70; }
        } else {
            r.p1 = (int)val1;
            r.d1 = val2;
        }
        if(r.p1 == 0) r.p1 = 14;
        r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) {
            rules[nRules] = r;
            nRules++;
        }
    }

    // Estocastico
    findIdx = StringFind(txt, "estocástico");
    if(findIdx < 0) findIdx = StringFind(txt, "stoch");
    if(findIdx >= 0) {
        cursor = findIdx + 5;
        r.Reset();
        r.intent = intent;
        r.tf = p_frequency;
        r.type = 3;
        r.active = true;
        r.p1 = 5; r.p2 = 3; r.p3 = 3;
        r.handle1 = iStochastic(_Symbol, r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
        if(r.handle1 != INVALID_HANDLE) {
            rules[nRules] = r;
            nRules++;
        }
    }

    // Delta
    findIdx = StringFind(txt, "delta");
    if(findIdx < 0) findIdx = StringFind(txt, "agressão");
    if(findIdx >= 0) {
        cursor = findIdx + 5;
        r.Reset();
        r.intent = intent;
        r.type = 6;
        r.active = true;
        r.p1 = 60; // segundos
        r.p2 = (int)ExtraiNumero(txt, cursor);
        if(r.p2 == 0) r.p2 = 300;
        rules[nRules] = r;
        nRules++;
    }

    // Bollinger Bands
    findIdx = StringFind(txt, "bollinger");
    if(findIdx >= 0) {
        cursor = findIdx + 9;
        r.Reset();
        r.intent = intent;
        r.tf = p_frequency;
        r.type = 4;
        r.active = true;
        r.p1 = (int)ExtraiNumero(txt, cursor); if(r.p1 == 0) r.p1 = 20;
        r.d1 = ExtraiNumero(txt, cursor); if(r.d1 == 0) r.d1 = 2.0;
        r.handle1 = iBands(_Symbol, r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) {
            rules[nRules] = r;
            nRules++;
        }
    }

    // Daily Breakout
    findIdx = StringFind(txt, "máxima") >= 0 || StringFind(txt, "mínima") >= 0;
    if(findIdx) {
        r.Reset();
        r.intent = intent;
        r.type = 5;
        r.active = true;
        rules[nRules] = r;
        nRules++;
    }

    // Volume Cycle
    findIdx = StringFind(txt, "volume");
    if(findIdx >= 0) {
        r.Reset();
        r.intent = intent;
        r.tf = p_frequency;
        r.type = 7;
        r.active = true;
        r.p1 = 12; // default period
        rules[nRules] = r;
        nRules++;
    }

    // Patterns
    if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "candle") >= 0) {
        r.Reset();
        r.intent = intent;
        r.tf = p_frequency;
        r.type = 9;
        r.active = true;
        rules[nRules] = r;
        nRules++;
    }
}

double ExtraiNumero(string txt, int &cursor) {
    string res = "";
    bool found = false;
    for(int i = cursor; i < StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') c = '.';
            res += ShortToString(c);
            found = true;
        } else if(found) {
            cursor = i;
            break;
        }
        if(i == StringLen(txt) - 1) cursor = i + 1;
    }
    return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    StringToLower(nome);
    if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
    if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
    if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
    if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

void ResetStrategy() {
    for(int i=0; i<20; i++) rules[i].Reset();
    nRules = 0;
    p_riskPercent = 1.0;
    p_stopLoss = 300;
    p_takeProfit = 500;
    p_maxTrades = 3;
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStop = 0;
    p_trailingStep = 0;
    p_startTime = "00:00";
    p_martingale = false;
    p_newsVeto = 20;
    p_frequency = PERIOD_M15;
}

// --- Signal Evaluation ---
Signal AvaliaTudo() {
    int buyVotes = 0;
    int sellVotes = 0;
    int buyConfirmations = 0;
    int sellConfirmations = 0;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;
        Signal s = AvaliaRegra(rules[i]);
        if(rules[i].intent == BUY) {
            buyVotes++;
            if(s == BUY) buyConfirmations++;
        } else if(rules[i].intent == SELL) {
            sellVotes++;
            if(s == SELL) sellConfirmations++;
        }
    }

    if(buyVotes > 0 && buyConfirmations == buyVotes) return BUY;
    if(sellVotes > 0 && sellConfirmations == sellVotes) return SELL;

    return NONE;
}

Signal AvaliaRegra(Rule &r) {
    // 1: MA
    if(r.type == 1) {
        double ma1 = GetBufferValue(r.handle1, 0, 1);
        double ma2 = GetBufferValue(r.handle1, 0, 2);
        double close1 = iClose(_Symbol, r.tf, 1);
        double close2 = iClose(_Symbol, r.tf, 2);

        if(r.intent == BUY && close2 < ma2 && close1 > ma1) return BUY;
        if(r.intent == SELL && close2 > ma2 && close1 < ma1) return SELL;
    }

    // 2: RSI
    if(r.type == 2) {
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);

        if(r.intent == BUY && rsi2 < r.d1 && rsi1 > r.d1) return BUY;
        if(r.intent == SELL && rsi2 > r.d1 && rsi1 < r.d1) return SELL;
    }

    // 3: Stoch
    if(r.type == 3) {
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);

        if(r.intent == BUY && k2 < d2 && k1 > d1) return BUY;
        if(r.intent == SELL && k2 > d2 && k1 < d1) return SELL;
    }

    // 6: Delta
    if(r.type == 6) {
        MqlTick arr[];
        int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buy = 0, sell = 0;
        for(int i=0; i<n; i++) {
            if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
            else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
        }
        long delta = buy - sell;
        if(r.intent == BUY && delta > r.p2) return BUY;
        if(r.intent == SELL && delta < -r.p2) return SELL;
    }

    // 4: BB
    if(r.type == 4) {
        double upper = GetBufferValue(r.handle1, 1, 1);
        double lower = GetBufferValue(r.handle1, 2, 1);
        double close = iClose(_Symbol, r.tf, 1);
        if(r.intent == BUY && close < lower) return BUY;
        if(r.intent == SELL && close > upper) return SELL;
    }

    // 5: DailyBreak
    if(r.type == 5) {
        double hi = iHigh(_Symbol, PERIOD_D1, 1);
        double lo = iLow(_Symbol, PERIOD_D1, 1);
        double close = iClose(_Symbol, r.tf, 1);
        if(r.intent == BUY && close > hi) return BUY;
        if(r.intent == SELL && close < lo) return SELL;
    }

    // 7: Volume
    if(r.type == 7) {
        long vol[];
        if(CopyVolume(_Symbol, r.tf, 0, r.p1, vol) > 0) {
            int max_idx = ArrayMaximum(vol);
            int min_idx = ArrayMinimum(vol);
            if(r.intent == BUY && min_idx == 0) return BUY;
            if(r.intent == SELL && max_idx == 0) return SELL;
        }
    }

    // 9: Pattern (Inside/Outside)
    if(r.type == 9) {
        double h0 = iHigh(_Symbol, r.tf, 1);
        double l0 = iLow(_Symbol, r.tf, 1);
        double h1 = iHigh(_Symbol, r.tf, 2);
        double l1 = iLow(_Symbol, r.tf, 2);
        bool inside = (h0 < h1 && l0 > l1);
        bool outside = (h0 > h1 && l0 < l1);
        bool bullish = (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1));

        if(r.intent == BUY && ((inside && bullish) || (outside && bullish))) return BUY;
        if(r.intent == SELL && ((inside && !bullish) || (outside && !bullish))) return SELL;
    }

    return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
    double val[1];
    if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
    return 0;
}

// --- Trade Execution & Position Management ---
void EnviaOrdem(Signal s) {
    if(PositionsTotal() >= p_maxTrades) return;
    if(AguardaNoticias()) return;
    if(!IsTimeAllowed()) return;

    double lote = CalculaLote();
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (s == BUY) ? price - p_stopLoss * _Point : price + p_stopLoss * _Point;
    double tp = (s == BUY) ? price + p_takeProfit * _Point : price - p_takeProfit * _Point;

    trade.SetExpertMagicNumber(EA_MAGIC);

    bool res = false;
    for(int i=0; i<3; i++) {
        if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
        else res = trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");

        if(res) break;

        uint code = trade.ResultRetcode();
        if(code == TRADE_RETCODE_REQUOTES || code == TRADE_RETCODE_OFFQUOTES) {
            symbol.Refresh();
            price = (s == BUY) ? symbol.Ask() : symbol.Bid();
            continue;
        } else {
            break;
        }
    }

    if(res) {
        GravaLog(StringFormat("Ordem %s enviada: Lote %.2f, SL %d, TP %d", (s == BUY ? "BUY" : "SELL"), lote, p_stopLoss, p_takeProfit));
        SendNotification("Trade executado: " + (s == BUY ? "BUY " : "SELL ") + _Symbol);
    } else {
        GravaLog("Erro ao enviar ordem: " + (string)trade.ResultRetcode());
    }
}

double CalculaLote() {
    double risk = p_riskPercent;
    if(p_martingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                if(profit < 0) risk *= 2;
                break;
            }
        }
    }

    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = equity * (risk / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(p_stopLoss == 0) return 0.01;

    double lot = riskAmount / ((p_stopLoss * _Point / tickSize) * tickValue);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot = MathFloor(lot / step) * step;
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    return lot;
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(pos.SelectByIndex(i) && pos.Magic() == EA_MAGIC && pos.Symbol() == _Symbol) {
            double openPrice = pos.PriceOpen();
            double currentPrice = (pos.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profitPoints = (pos.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

            // Breakeven
            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (pos.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if(pos.PositionType() == POSITION_TYPE_BUY && (pos.StopLoss() < openPrice || pos.StopLoss() == 0)) {
                    trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
                } else if(pos.PositionType() == POSITION_TYPE_SELL && (pos.StopLoss() > openPrice || pos.StopLoss() == 0)) {
                    trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (pos.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
                if(pos.PositionType() == POSITION_TYPE_BUY) {
                    if(newSL > pos.StopLoss() + p_trailingStep * _Point) {
                        trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
                    }
                } else {
                    if(newSL < pos.StopLoss() - p_trailingStep * _Point || pos.StopLoss() == 0) {
                        trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
                    }
                }
            }
        }
    }
}

bool IsTimeAllowed() {
    datetime now = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(now, dt);
    string currentTime = StringFormat("%02d:%02d", dt.hour, dt.min);
    return (currentTime >= p_startTime);
}

// --- Utility & Event Handlers ---
void GravaLog(string txt) {
    int h = FileOpen(LOG_FILE, FILE_WRITE | FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWrite(h, TimeToString(TimeCurrent()) + ": " + txt);
        FileClose(h);
    }
}

void GravaCSV() {
    if(TimeCurrent() - last_csv < 5) return;
    last_csv = TimeCurrent();

    int h = FileOpen(STATE_FILE, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "OpenPrice", "Profit", "SL", "TP");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(pos.SelectByIndex(i)) {
                FileWrite(h, pos.Ticket(), pos.Symbol(), pos.PositionType(), pos.PriceOpen(), pos.Profit(), pos.StopLoss(), pos.TakeProfit());
            }
        }
        FileClose(h);
    }
}

bool AguardaNoticias() {
    // 1. Check news_veto.txt
    int h = FileOpen(NEWS_VETO_FILE, FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string val = FileReadString(h);
        FileClose(h);
        if(val == "1" || val == "true") return true;
    }

    // 2. Scan calendar.txt
    h = FileOpen(CALENDAR_FILE, FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        datetime now = TimeCurrent();
        while(!FileIsEnding(h)) {
            string line = FileReadString(h);
            if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
                // Heuristica: Procura por um horario HH:MM na mesma linha
                int pos_sep = StringFind(line, ":");
                if(pos_sep > 0) {
                    int hh = (int)StringToInteger(StringSubstr(line, pos_sep - 2, 2));
                    int mm = (int)StringToInteger(StringSubstr(line, pos_sep + 1, 2));

                    MqlDateTime dt;
                    TimeToStruct(now, dt);
                    dt.hour = hh;
                    dt.min = mm;
                    dt.sec = 0;
                    datetime newsTime = StructToTime(dt);

                    // Se a noticia for hoje e estiver dentro do veto
                    if(MathAbs(now - newsTime) < p_newsVeto * 60) {
                        FileClose(h);
                        return true;
                    }
                } else {
                    // Fallback se nao achar horario mas for de alto impacto
                    FileClose(h);
                    return true;
                }
            }
        }
        FileClose(h);
    }
    return false;
}

void AIOptimizer() {
    if(TimeCurrent() - last_ai < 3600) return;
    last_ai = TimeCurrent();

    HistorySelect(TimeCurrent() - 86400, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, count = 0;
    for(int i = total - 1; i >= 0 && count < 10; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
            count++;
        }
    }

    if(count >= 5 && (double)wins/count < 0.4) {
        p_riskPercent *= 0.8;
        GravaLog("AI Optimizer: Reduzindo risco devido a baixa taxa de acerto.");
    }
}

void CalculaStats() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    double totalProfit = 0;
    int wins = 0, losses = 0;
    for(int i = 0; i < total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            totalProfit += profit;
            if(profit > 0) wins++;
            else if(profit < 0) losses++;
        }
    }
    double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
    GravaLog(StringFormat("Stats: WinRate %.2f%%, TotalProfit %.2f", winRate, totalProfit));
}

int OnInit() {
    symbol.Name(_Symbol);
    account.Login();
    EventSetTimer(1);
    InterpretaPrompt("A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 300 pontos, take de 500 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
}

void OnTick() {
    GerenciaPosicoes();
    GravaCSV();

    datetime current_bar = iTime(_Symbol, p_frequency, 0);
    if(current_bar != last_bar) {
        last_bar = current_bar;
        Signal s = AvaliaTudo();
        if(s != NONE) EnviaOrdem(s);
    }
}

void OnTimer() {
    // Verificar se ha novo prompt
    int h = FileOpen(PROMPT_FILE, FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string new_prompt = FileReadString(h);
        FileClose(h);
        if(new_prompt != "" && new_prompt != p_prompt) {
            InterpretaPrompt(new_prompt);
        }
    }

    AIOptimizer();
}
