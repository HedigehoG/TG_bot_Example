import os
import asyncio
from aiohttp import web
from dotenv import load_dotenv

load_dotenv()

from aiogram import Bot, Dispatcher
from aiogram.types import Update, Message
from aiogram.filters import Command

BOT_TOKEN = os.getenv('BOT_TOKEN')
# Публичный адрес, на который Telegram будет отправлять обновления
WEBHOOK_HOST = os.getenv('WEBHOOK_HOST')
# Хост и порт, которые будет слушать наше приложение ВНУТРИ контейнера
LISTEN_HOST = os.getenv('HOST', '0.0.0.0')
LISTEN_PORT = int(os.getenv('PORT', 8080))

if not BOT_TOKEN or not WEBHOOK_HOST:
    raise SystemExit('Please set BOT_TOKEN and WEBHOOK_HOST in your environment (.env file)')

# Используем простой и статический путь. Маршрутизация будет осуществляться через поддомен.
WEBHOOK_PATH = "/webhook"
WEBHOOK_URL = f"{WEBHOOK_HOST}{WEBHOOK_PATH}"

bot = Bot(BOT_TOKEN)
dp = Dispatcher()

@dp.message(Command(commands=['start']))
async def cmd_start(message: Message):
    await message.answer('Привет! Я работаю через вебхуки.')

@dp.message()
async def echo(message: Message):
    text = message.text or '<non-text>'
    await message.answer(f'Вы написали: {text}')

async def handle(request: web.Request) -> web.Response:
    try:
        data = await request.json()
    except Exception:
        return web.Response(status=400, text='invalid json')
    update = Update(**data)
    # feed update into dispatcher
    await dp.feed_update(update)
    return web.Response(status=200)

async def on_startup(app: web.Application):
    await bot.set_webhook(WEBHOOK_URL)
    app['bot'] = bot
    print('Webhook set to', WEBHOOK_URL)

async def on_shutdown(app: web.Application):
    bot = app.get('bot')
    if bot:
        await bot.delete_webhook()
        await bot.session.close()

app = web.Application()
app.router.add_post(WEBHOOK_PATH, handle)
app.router.add_get('/', lambda request: web.Response(text='tg-webhook-bot: ok'))
app.on_startup.append(on_startup)
app.on_cleanup.append(on_shutdown)

if __name__ == '__main__':
    # Запускаем приложение с правильными хостом и портом
    web.run_app(app, host=LISTEN_HOST, port=LISTEN_PORT)
