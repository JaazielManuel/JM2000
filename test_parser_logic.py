import re

def period_to_minutes(period_str):
    period_str = period_str.lower()
    if 'm1' == period_str or '1 minuto' in period_str: return 1
    if 'm5' == period_str or '5 minutos' in period_str: return 5
    if 'm15' == period_str or '15 minutos' in period_str: return 15
    if 'm30' == period_str or '30 minutos' in period_str: return 30
    if 'h1' == period_str or '1 hora' in period_str: return 60
    if 'h4' == period_str or '4 horas' in period_str: return 240
    if 'd1' == period_str or 'diário' in period_str: return 1440
    return 15 # Default

def test_parser(prompt):
    print(f"Parsing prompt: {prompt}")

    # Normalizing
    prompt = prompt.lower().replace(',', '.')

    # Extracting parameters
    params = {}

    # Frequency
    freq_match = re.search(r'a cada (\d+) (minutos|min|m)', prompt)
    if freq_match:
        params['frequency'] = int(freq_match.group(1))

    # Start Hour
    hour_match = re.search(r'(depois das|após as) (\d+)h', prompt)
    if hour_match:
        params['start_hour'] = int(hour_match.group(2))

    # Stop Loss
    sl_match = re.search(r'stop de (\d+) pontos', prompt)
    if sl_match:
        params['stop_loss'] = int(sl_match.group(1))

    # Take Profit
    tp_match = re.search(r'take de (\d+) pontos', prompt)
    if tp_match:
        params['take_profit'] = int(tp_match.group(1))

    # Risk
    risk_match = re.search(r'risco de (\d+\.?\d*) %', prompt)
    if risk_match:
        params['risk'] = float(risk_match.group(1))

    # Breakeven
    be_match = re.search(r'ao atingir \+(\d+) pontos. move stop para entrada \+(\d+) pontos', prompt)
    if be_match:
        params['breakeven_trigger'] = int(be_match.group(1))
        params['breakeven_step'] = int(be_match.group(2))

    # Indicators - Simplified simulation
    rules = []
    if 'média de 20' in prompt:
        rules.append({'type': 'MA', 'period': 20})
    if 'rsi (14)' in prompt:
        rules.append({'type': 'RSI', 'period': 14})

    params['rules'] = rules

    print(f"Extracted Params: {params}")
    return params

if __name__ == "__main__":
    example_prompt = "A cada 15 minutos. depois das 10h. compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos. take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos. move stop para entrada +5 pontos."
    res = test_parser(example_prompt)
    if res.get('frequency') == 15 and res.get('start_hour') == 10 and res.get('stop_loss') == 30:
        print("NLP Parser Test Passed")
    else:
        print("NLP Parser Test Failed")
        import sys
        sys.exit(1)
