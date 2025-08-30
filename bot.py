import os
import asyncio
import json
from aiohttp import web
from dotenv import load_dotenv
import logging

load_dotenv()

from aiogram import Bot, Dispatcher
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import Message, Update
from aiogram.filters import Command

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(name)s - %(message)s')

BOT_TOKEN = os.getenv('BOT_TOKEN')
# Публичный адрес, на который Telegram будет отправлять обновления
WEBHOOK_HOST = os.getenv('WEBHOOK_HOST')
# Хост, который будет слушать наше приложение ВНУТРИ контейнера
LISTEN_HOST = os.getenv('HOST', '0.0.0.0')
# Внутренний порт приложения. Для Docker-окружения это значение обычно является
# константой, но мы берем его из .env для единообразия.
# Внешний порт настраивается через проброс портов в Docker.
LISTEN_PORT = int(os.getenv('LISTEN_PORT', '8080'))
# Секретный токен для верификации вебхуков. Для простоты можно использовать токен бота.
# Скрипт bootstrap-server-custom.sh генерирует его автоматически.
WEBHOOK_SECRET = os.getenv('WEBHOOK_SECRET')

if not all([BOT_TOKEN, WEBHOOK_HOST, WEBHOOK_SECRET]):
    raise SystemExit('ОШИБКА: Убедитесь, что переменные BOT_TOKEN, WEBHOOK_HOST и WEBHOOK_SECRET заданы в .env файле или окружении.')
if not WEBHOOK_HOST.startswith("https://"):
    logging.warning("WEBHOOK_HOST не начинается с https://. Telegram требует HTTPS для вебхуков.")

# Используем простой и статический путь. Маршрутизация будет осуществляться через поддомен.
WEBHOOK_PATH = "/webhook"
# Убираем возможное / в конце, чтобы избежать двойного слеша //
WEBHOOK_URL = f"{WEBHOOK_HOST.rstrip('/')}{WEBHOOK_PATH}"

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher(storage=MemoryStorage())

@dp.message(Command(commands=['start']))
async def cmd_start(message: Message):
    await message.answer('Привет! Я работаю через вебхуки.')

@dp.message()
async def echo(message: Message):
    text = message.text or '<non-text>'
    await message.answer(f'Вы написали: {text}')

@dp.message(Command(commands=['webhookinfo']))
async def cmd_webhook_info(message: Message, bot: Bot):
    """Диагностическая команда для проверки статуса вебхука."""
    try:
        info = await bot.get_webhook_info()
        info_json = json.dumps(info.dict(), indent=2, ensure_ascii=False)
        await message.answer(f"<pre>{info_json}</pre>", parse_mode="HTML")
    except Exception as e:
        await message.answer(f"Не удалось получить информацию о вебхуке: {e}")

async def handle(request: web.Request) -> web.Response:
    try:
        # Проверяем секретный токен, который Telegram передает в заголовке
        # ВРЕМЕННО ОТКЛЮЧЕНО ДЛЯ ОТЛАДКИ
        # secret_token = request.headers.get("X-Telegram-Bot-Api-Secret-Token")
        # if secret_token != WEBHOOK_SECRET: ...

        bot: Bot = request.app['bot']
        update_data = await request.json()
        update = Update(**update_data)
        await dp.feed_update(bot=bot, update=update)
        return web.Response()  # Возвращаем 200 OK без тела
    except Exception as e:
        logging.error("Error processing update: %s", e, exc_info=True)
        # Отвечаем 200 OK, чтобы Telegram не пересылал "сломанное" обновление.
        return web.Response(status=200, text="ok")

async def on_startup(app: web.Application):
    # При запуске бота удаляем старые, неотвеченные апдейты,
    # и устанавливаем вебхук с секретным токеном.
    # ВРЕМЕННО: Упрощенный запуск для отладки без повторных попыток и без secret_token.
    app['bot'] = bot
    logging.warning("!!! РЕЖИМ ОТЛАДКИ: Попытка установить вебхук один раз и без secret_token. !!!")
    try:
        await bot.delete_webhook(drop_pending_updates=True)
        # Временно отключаем передачу secret_token для чистоты эксперимента
        await bot.set_webhook(url=WEBHOOK_URL)
        logging.info('Webhook successfully set to %s (БЕЗ secret_token)', WEBHOOK_URL)
    except Exception as e:
        logging.critical("Failed to set webhook on startup: %s", e, exc_info=True)

async def health_check(request):
    """Простой ответ для healthcheck'а от Docker."""
    return web.Response(text="OK")

async def on_shutdown(app: web.Application):
    logging.info("Gracefully shutting down...")
    bot = app.get('bot')
    if bot:
        await bot.delete_webhook()
        await dp.storage.close()
        await bot.session.close()

app = web.Application()
app.router.add_post(WEBHOOK_PATH, handle)
app.router.add_get("/health", health_check)
# ---------------------------

app.on_startup.append(on_startup)
app.on_shutdown.append(on_shutdown)


if __name__ == '__main__':
    logging.info("Starting bot...")
    # Маскируем токен в логах для безопасности
    logging.info(" - Bot Token: %s", f"{'*' * (len(BOT_TOKEN) - 4) + BOT_TOKEN[-4:] if BOT_TOKEN else 'Not set'}")
    logging.info(" - Webhook URL: %s", WEBHOOK_URL)
    logging.info(" - Listening on: %s:%s", LISTEN_HOST, LISTEN_PORT)
    # Запускаем приложение с правильными хостом и портом
    web.run_app(app, host=LISTEN_HOST, port=LISTEN_PORT)
