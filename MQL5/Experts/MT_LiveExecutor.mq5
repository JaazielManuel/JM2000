//=========================  MT-LiveExecutor  =========================
// Módulo Único de Execução de Estratégias em Tempo Real
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- DEFINIÇÕES E ENUMS ----------
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

// Tipos de Regras Suportadas
#define RT_MA          1
#define RT_RSI         2
#define RT_STOCH       3
#define RT_BB          4
#define RT_DAILYBREAK  5
#define RT_DELTA       6
#define RT_VOL         7
#define RT_AMA         8
#define RT_BAR2        9
#define RT_RS          10
#define RT_AI          11

struct Rule {
    int         type;       // RT_*
    ENUM_SIGNAL intent;     // BUY ou SELL
    int         timeframe;
    double      p1, p2, p3; // Parâmetros numéricos
    string      s1;         // Parâmetro de texto (ex: benchmark)
    int         handle1;    // Handle do indicador 1
    int         handle2;    // Handle do indicador 2

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        type = 0;
        intent = SIGNAL_NONE;
        timeframe = PERIOD_CURRENT;
        p1 = p2 = p3 = 0;
        s1 = "";
        handle1 = handle2 = INVALID_HANDLE;
    }
};

// ---------- VARIÁVEIS GLOBAIS ----------
Rule        rules[20];
int         nRules = 0;
CTrade      trade;
CPositionInfo posInfo;
CSymbolInfo  symbolInfo;

// Parâmetros da Estratégia
double      p_riskPercent   = 1.0;
int         p_stopPoints    = 0;
int         p_takeProfit    = 0;
int         p_maxTrades     = 3;
int         p_beStart       = 0;
int         p_bePlus        = 0;
int         p_trailingStop  = 0;
int         p_trailingStep  = 0;
string      p_startTime     = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;
bool        p_useMartingale = false;

long        EA_MAGIC = 123456;
datetime    lastPromptUpdate = 0;

// ---------- FUNÇÕES AUXILIARES ----------

// Extrai número de uma string a partir de uma posição
double ExtraiNumero(string text, int &pos) {
    string res = "";
    bool found = false;
    int len = StringLen(text);
    for(int i = pos; i < len; i++) {
        ushort c = StringGetCharacter(text, i);
        if((c >= '0' && c <= '9') || c == '.') {
            res += CharToString((uchar)c);
            found = true;
        } else if(found) {
            pos = i;
            return StringToDouble(res);
        }
    }
    pos = len;
    return (found) ? StringToDouble(res) : 0;
}

// Extrai valor numérico após uma palavra-chave
double ExtraiValorApos(string text, string keyword) {
    int p = StringFind(text, keyword);
    if(p < 0) return 0;
    p += StringLen(keyword);
    return ExtraiNumero(text, p);
}

// Converte texto para ENUM_TIMEFRAMES
ENUM_TIMEFRAMES PeriodoTexto(string text) {
    if(StringFind(text, "m1") >= 0 && StringFind(text, "m15") < 0)  return PERIOD_M1;
    if(StringFind(text, "m5") >= 0 && StringFind(text, "m15") < 0)  return PERIOD_M5;
    if(StringFind(text, "m15") >= 0) return PERIOD_M15;
    if(StringFind(text, "m30") >= 0) return PERIOD_M30;
    if(StringFind(text, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(text, "h4") >= 0)  return PERIOD_H4;
    if(StringFind(text, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

// Reseta a estratégia atual
void ResetStrategy() {
    for(int i = 0; i < 20; i++) rules[i].Reset();
    nRules = 0;
    p_riskPercent = 1.0; p_stopPoints = 0; p_takeProfit = 0;
    p_maxTrades = 3; p_beStart = 0; p_bePlus = 0;
    p_trailingStop = 0; p_trailingStep = 0;
    p_startTime = "00:00"; p_frequency = PERIOD_CURRENT;
    p_useMartingale = false;
}

// ---------- MOTOR DE PROCESSAMENTO DE LINGUAGEM NATURAL ----------

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string work = prompt;
    StringToLower(work);

    // Configurações Globais
    p_riskPercent = ExtraiValorApos(work, "risco de");
    if(p_riskPercent == 0) p_riskPercent = 1.0;

    p_stopPoints = (int)ExtraiValorApos(work, "stop de");
    p_takeProfit = (int)ExtraiValorApos(work, "take de");

    double mt = ExtraiValorApos(work, "máximo");
    if(mt > 0) p_maxTrades = (int)mt;

    p_beStart = (int)ExtraiValorApos(work, "atingir");
    p_bePlus = (int)ExtraiValorApos(work, "entrada +");

    p_trailingStop = (int)ExtraiValorApos(work, "trailing stop");

    if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

    // Frequência de Execução
    p_frequency = PeriodoTexto(work);

    // Horário de Início
    int tPos = StringFind(work, "depois das");
    if(tPos >= 0) {
        int h = (int)ExtraiNumero(work, tPos);
        p_startTime = IntegerToString(h, 2, '0') + ":00";
    }

    // Divisão por Segmentos (Regras)
    string segments[];
    string sep = "|";
    StringReplace(work, " e ", sep);
    StringReplace(work, ".", sep);
    StringReplace(work, ",", sep);
    int nSeg = StringSplit(work, StringGetCharacter(sep, 0), segments);
    ENUM_SIGNAL currentIntent = SIGNAL_NONE;

    for(int i = 0; i < nSeg && nRules < 20; i++) {
        string seg = segments[i];
        if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SIGNAL_SELL;

        if(currentIntent == SIGNAL_NONE) continue;

        Rule r; r.Reset();
        r.intent = currentIntent;
        r.timeframe = PeriodoTexto(seg);
        if(r.timeframe == PERIOD_CURRENT) r.timeframe = p_frequency;

        // MA
        if(StringFind(seg, " média ") >= 0 || StringFind(seg, " ma ") >= 0) {
            r.type = RT_MA;
            int p = 0;
            r.p1 = ExtraiNumero(seg, p);
            r.p2 = ExtraiNumero(seg, p); // Se houver segunda média
            if(r.p1 == 0) r.p1 = 20;

            r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, (int)r.p1, 0, MODE_SMA, PRICE_CLOSE);
            if(r.p2 > 0)
                r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, (int)r.p2, 0, MODE_SMA, PRICE_CLOSE);

            rules[nRules++] = r;
        }
        // RSI
        else if(StringFind(seg, "rsi") >= 0) {
            r.type = RT_RSI;
            int p = StringFind(seg, "rsi") + 3;
            double n1 = ExtraiNumero(seg, p);
            double n2 = ExtraiNumero(seg, p);

            if(n1 > 0 && n2 > 0) { r.p1 = n1; r.p2 = n2; }
            else if(n1 >= 40)    { r.p1 = 14; r.p2 = n1; }
            else if(n1 > 0)     { r.p1 = n1; r.p2 = (currentIntent == SIGNAL_BUY) ? 30 : 70; }
            else                { r.p1 = 14; r.p2 = (currentIntent == SIGNAL_BUY) ? 30 : 70; }

            r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, (int)r.p1, PRICE_CLOSE);
            rules[nRules++] = r;
        }
        // Bollinger
        else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, " bb ") >= 0) {
            r.type = RT_BB;
            r.p1 = 20; r.p2 = 2.0; // Defaults
            r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, (int)r.p1, 0, r.p2, PRICE_CLOSE);
            rules[nRules++] = r;
        }
        // Daily Breakout
        else if(StringFind(seg, "rompimento diário") >= 0) {
            r.type = RT_DAILYBREAK;
            rules[nRules++] = r;
        }
        // Delta Aggression
        else if(StringFind(seg, "delta") >= 0) {
            r.type = RT_DELTA;
            int p = StringFind(seg, "delta") + 5;
            r.p1 = ExtraiNumero(seg, p); // Segundos
            r.p2 = ExtraiNumero(seg, p); // Trigger threshold
            if(r.p1 == 0) r.p1 = 60;
            if(r.p2 == 0) r.p2 = 300;
            rules[nRules++] = r;
        }
        // Volume
        else if(StringFind(seg, "volume") >= 0) {
            r.type = RT_VOL;
            rules[nRules++] = r;
        }
        // AMA
        else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
            r.type = RT_AMA;
            r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 10, 2, 30, 0, PRICE_CLOSE);
            rules[nRules++] = r;
        }
        // Pattern 2 Bar
        else if(StringFind(seg, "padrão barras") >= 0) {
            r.type = RT_BAR2;
            rules[nRules++] = r;
        }
        // AI Signal
        else if(StringFind(seg, "ai") >= 0 || StringFind(seg, "previsão") >= 0) {
            r.type = RT_AI;
            r.handle1 = iATR(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 14);
            rules[nRules++] = r;
        }
    }
}

// ---------- PERSISTÊNCIA E LOGGING ----------

void GravaCSV() {
    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "SL", "TP", "Profit", "Comment");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
                FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(),
                          posInfo.Volume(), posInfo.PriceOpen(), posInfo.StopLoss(),
                          posInfo.TakeProfit(), posInfo.Commission() + posInfo.Swap() + posInfo.Profit(),
                          posInfo.Comment());
            }
        }
        FileClose(handle);
    }
}

void GravaLog(string text) {
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()) + ": " + text);
        FileClose(handle);
    }
}

bool AguardaNoticias() {
    if(FileIsExist("news_veto.txt")) {
        int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
        if(handle != INVALID_HANDLE) {
            string content = FileReadString(handle);
            FileClose(handle);
            if(StringFind(content, "true") >= 0) return true;
        }
    }
    return false;
}

void AIOptimizer() {
    static datetime lastOpt = 0;
    if(TimeCurrent() - lastOpt < 3600) return;
    lastOpt = TimeCurrent();

    HistorySelect(TimeCurrent() - 86400, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, losses = 0;
    for(int i = 0; i < total; i++) {
        ulong t = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT);
            if(p > 0) wins++; else if(p < 0) losses++;
        }
    }
    if(wins + losses > 5 && (double)wins/(wins+losses) < 0.4) {
        p_riskPercent *= 0.8;
        GravaLog("AI Optimizer: Risco reduzido para " + DoubleToString(p_riskPercent, 2));
    }
}

// ---------- MOTOR DE SINAIS ----------

double GetBufferValue(int handle, int buffer, int index) {
    double val[];
    ArraySetAsSeries(val, true);
    if(CopyBuffer(handle, buffer, index, 1, val) > 0) return val[0];
    return 0;
}

ENUM_SIGNAL AvaliaRegra(Rule &r) {
    if(r.type == RT_MA) {
        double m1 = GetBufferValue(r.handle1, 0, 1);
        double m2 = GetBufferValue(r.handle1, 0, 2);
        double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 1);
        double p2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 2);

        if(r.handle2 != INVALID_HANDLE) {
            double s1 = GetBufferValue(r.handle2, 0, 1);
            double s2 = GetBufferValue(r.handle2, 0, 2);
            if(m2 < s2 && m1 > s1) return SIGNAL_BUY;
            if(m2 > s2 && m1 < s1) return SIGNAL_SELL;
        } else {
            if(p2 < m2 && p1 > m1) return SIGNAL_BUY;
            if(p2 > m2 && p1 < m1) return SIGNAL_SELL;
        }
    }
    else if(r.type == RT_RSI) {
        double v1 = GetBufferValue(r.handle1, 0, 1);
        double v2 = GetBufferValue(r.handle1, 0, 2);
        if(r.intent == SIGNAL_BUY && v2 < r.p2 && v1 > r.p2) return SIGNAL_BUY;
        if(r.intent == SIGNAL_SELL && v2 > r.p2 && v1 < r.p2) return SIGNAL_SELL;
    }
    else if(r.type == RT_BB) {
        double up = GetBufferValue(r.handle1, 1, 1);
        double lw = GetBufferValue(r.handle1, 2, 1);
        double cl = iClose(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 1);
        if(cl < lw) return SIGNAL_BUY;
        if(cl > up) return SIGNAL_SELL;
    }
    else if(r.type == RT_DAILYBREAK) {
        double hi = iHigh(_Symbol, PERIOD_D1, 1);
        double lo = iLow(_Symbol, PERIOD_D1, 1);
        double cl = iClose(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 0);
        if(cl > hi) return SIGNAL_BUY;
        if(cl < lo) return SIGNAL_SELL;
    }
    else if(r.type == RT_AI) {
        double atr = GetBufferValue(r.handle1, 0, 1);
        double body = MathAbs(iClose(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 1) - iOpen(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 1));
        bool bullish = iClose(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.timeframe, 1);
        if(body > 1.5 * atr) return (bullish) ? SIGNAL_BUY : SIGNAL_SELL;
    }
    return SIGNAL_NONE;
}

ENUM_SIGNAL AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i = 0; i < nRules; i++) {
        ENUM_SIGNAL res = AvaliaRegra(rules[i]);
        if(rules[i].intent == SIGNAL_BUY) {
            buyRules++;
            if(res == SIGNAL_BUY) buyVotes++;
        } else if(rules[i].intent == SIGNAL_SELL) {
            sellRules++;
            if(res == SIGNAL_SELL) sellVotes++;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) return SIGNAL_BUY;
    if(sellRules > 0 && sellVotes == sellRules) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// ---------- EVENTOS DO EXPERT ----------

int OnInit() {
    EventSetTimer(1);
    lastPromptUpdate = 0;
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    for(int i = 0; i < 20; i++) rules[i].Reset();
}

void OnTimer() {
    // Monitora arquivo de prompt para atualizações ao vivo
    if(FileIsExist("prompt.txt")) {
        datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
        if(mod > lastPromptUpdate) {
            int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
            if(handle != INVALID_HANDLE) {
                string prompt = FileReadString(handle);
                FileClose(handle);
                InterpretaPrompt(prompt);
                lastPromptUpdate = mod;
                GravaLog("Nova estratégia carregada: " + prompt);
            }
        }
    }

    AIOptimizer();
    GravaCSV();
}

void OnTick() {
    // Filtro de Horário
    MqlDateTime dt;
    TimeCurrent(dt);
    string now = IntegerToString(dt.hour, 2, '0') + ":" + IntegerToString(dt.min, 2, '0');
    if(now < p_startTime) return;

    // Filtro de Notícias
    if(AguardaNoticias()) return;

    // Frequência de Operação (Novo Candle)
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar == lastBar) {
        GerenciaPosicoes(); // Gestão contínua
        return;
    }
    lastBar = currentBar;

    // Avaliação de Sinais
    ENUM_SIGNAL s = AvaliaTudo();
    if(s != SIGNAL_NONE) {
        EnviaOrdem(s, "Sinal confirmado por confluence");
    }

    GerenciaPosicoes();
}

// ---------- MOTOR DE EXECUÇÃO ----------

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_FREEMARGIN);
    double riscoAbs = capital * riscoPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    int stop = (p_stopPoints > 0) ? p_stopPoints : 300;
    double lot = riscoAbs / (stop * (tickValue / (tickSize / _Point)));

    if(p_useMartingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
                break;
            }
        }
    }

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    return lot;
}

void EnviaOrdem(ENUM_SIGNAL s, string reason) {
    if(s == SIGNAL_NONE) return;

    int openTrades = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) openTrades++;
    }
    if(openTrades >= p_maxTrades) return;

    double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = 0, tp = 0;
    double lot = CalculaLote(p_riskPercent);

    if(s == SIGNAL_BUY) {
        if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
        if(p_takeProfit > 0) tp = price + p_takeProfit * _Point;
    } else {
        if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
        if(p_takeProfit > 0) tp = price - p_takeProfit * _Point;
    }

    trade.SetExpertMagicNumber(EA_MAGIC);
    bool res = false;
    if(s == SIGNAL_BUY) res = trade.Buy(lot, _Symbol, price, sl, tp, reason);
    else res = trade.Sell(lot, _Symbol, price, sl, tp, reason);

    if(res) {
        SendNotification("MT-LiveExecutor: " + reason + " em " + _Symbol);
        Print("Ordem enviada com sucesso: ", reason);
    } else {
        Print("Erro ao enviar ordem: ", trade.ResultRetcode(), " - ", trade.ResultComment());
    }
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
            double priceOpen = posInfo.PriceOpen();
            double priceCurrent = posInfo.PriceCurrent();
            double sl = posInfo.StopLoss();
            double tp = posInfo.TakeProfit();

            // Breakeven
            if(p_beStart > 0) {
                if(posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if(priceCurrent >= priceOpen + p_beStart * _Point && (sl < priceOpen || sl == 0)) {
                        trade.PositionModify(posInfo.Ticket(), priceOpen + p_bePlus * _Point, tp);
                    }
                } else {
                    if(priceCurrent <= priceOpen - p_beStart * _Point && (sl > priceOpen || sl == 0)) {
                        trade.PositionModify(posInfo.Ticket(), priceOpen - p_bePlus * _Point, tp);
                    }
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0) {
                if(posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if(priceCurrent > priceOpen + p_trailingStop * _Point) {
                        double newSL = priceCurrent - p_trailingStop * _Point;
                        if(newSL > sl + p_trailingStep * _Point || sl == 0)
                            trade.PositionModify(posInfo.Ticket(), newSL, tp);
                    }
                } else {
                    if(priceCurrent < priceOpen - p_trailingStop * _Point) {
                        double newSL = priceCurrent + p_trailingStop * _Point;
                        if(newSL < sl - p_trailingStep * _Point || sl == 0)
                            trade.PositionModify(posInfo.Ticket(), newSL, tp);
                    }
                }
            }
        }
    }
}
