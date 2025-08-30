# Используем официальный образ Python.
# Если что-то не работает, зафиксируйте версию python:3.12-slim или ещё больше python:3.12-slim-bookworm с версией системы образа
# Текущая просто последняя 3я версия
FROM python:3-slim

# Устанавливаем рабочую директорию в контейнере
WORKDIR /app

# Устанавливаем curl для healthcheck и другие зависимости, затем очищаем кэш
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Копируем файл с зависимостями
COPY requirements.txt .

# Устанавливаем зависимости
RUN pip install --no-cache-dir -r requirements.txt

# Копируем остальной код приложения
COPY . .

# Делаем скрипт-обертку исполняемым. Он уже скопирован в /app вместе со всем кодом.
RUN chmod +x ./entrypoint.sh

# Теперь entrypoint.sh будет запускаться первым, а затем он запустит команду из CMD.
ENTRYPOINT ["./entrypoint.sh"]
CMD ["python", "bot.py"]