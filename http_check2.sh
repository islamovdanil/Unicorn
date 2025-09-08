#!/bin/bash

# Целевой URL
TARGET="http://localhost"
# Интервал проверки в секундах
INTERVAL=0.5
# Получаем hostname системы
HOSTNAME=$(hostname)

# Бесконечный цикл проверки
while true; do
    # Получаем текущую дату и время
    date '+%d/%m/%Y %H:%M:%S'
    
    curl -s -v --connect-timeout 0.3 $TARGET
   
    # Ждем заданный интервал
    sleep $INTERVAL
done
