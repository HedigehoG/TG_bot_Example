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

# Команда для запуска приложения
CMD ["python", "bot.py"]