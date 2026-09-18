#!/usr/bin/env python3
"""Telegram Web Proxy Bot — per-user profiles, admin access, pagination."""
import os, json, logging, math
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("tg_proxy_bot")

BOT_TOKEN = os.environ.get("TG_PROXY_BOT_TOKEN", "")
PROFILES_PATH = os.environ.get("TPROXY_PROFILES_PATH", "/etc/tproxy-server/profiles.json")
CONFIG_PATH = os.environ.get("TPROXY_CONFIG_PATH", "/etc/tproxy-server/config.json")
TG_MAPPINGS_PATH = os.environ.get("TPROXY_TG_MAPPINGS_PATH", "/etc/tproxy-server/tg_mappings.json")
ADMIN_IDS = [int(x) for x in os.environ.get("TG_PROXY_BOT_ADMINS", "").split(",") if x.strip()]

PROFILES_PER_PAGE = 5

CARRIER_LABELS = {
    "https": "HTTPS",
    "https-lanes": "HTTPS Lanes",
    "websocket": "WebSocket",
    "websocket-lanes": "WebSocket Lanes",
}


def load_profiles():
    try:
        with open(PROFILES_PATH) as f:
            return json.load(f).get("profiles", [])
    except Exception as e:
        logger.error("Failed to load profiles: %s", e)
        return []


def load_hostname():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f).get("public_hostname", "")
    except Exception:
        return ""


def load_tg_mappings():
    try:
        with open(TG_MAPPINGS_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def is_admin(user_id: int) -> bool:
    return user_id in ADMIN_IDS


def get_user_profiles(user_id: int, username: str | None):
    """Get profiles assigned to this user (by ID or @username). Admin gets all."""
    if is_admin(user_id):
        return load_profiles()
    all_profiles = load_profiles()
    mappings = load_tg_mappings()
    user_id_str = str(user_id)
    user_tag = f"@{username}" if username else None
    result = []
    for p in all_profiles:
        tg = mappings.get(p["name"], "").strip()
        if not tg:
            continue
        if tg == user_id_str:
            result.append(p)
        elif user_tag and tg.lower() == user_tag.lower():
            result.append(p)
    return result


def make_connect_url(hostname: str, secret: str) -> str:
    return f"https://t.me/webproxy?server={hostname}&secret={secret}"


def profile_block(p: dict, hostname: str) -> str:
    mode = CARRIER_LABELS.get(p.get("carrier_mode", "https"), p.get("carrier_mode", "https"))
    tg_user = p.get("telegram_user", "")
    lines = [
        f"\u26a1 <b>{p['name']}</b>",
        f"\U0001f4cd <b>\u0421\u0435\u0440\u0432\u0435\u0440:</b> <code>{hostname}</code>",
        f"\U0001f511 <b>\u0421\u0435\u043a\u0440\u0435\u0442:</b> <code>{p['secret']}</code>",
        f"\U0001f4e6 <b>\u0420\u0435\u0436\u0438\u043c:</b> {mode}",
    ]
    if tg_user:
        lines.append(f"\U0001f464 <b>\u041f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u044c:</b> <code>{tg_user}</code>")
    return "\n".join(lines)


UNAUTHORIZED_TEXT = (
    "\u274c <b>\u0423 \u0432\u0430\u0441 \u043d\u0435\u0442 \u0434\u043e\u0441\u0442\u0443\u043f\u0430.</b>\n\n"
    "\U0001f44b \u041f\u0440\u0438\u0432\u0435\u0442! \u0427\u0442\u043e\u0431\u044b \u043f\u043e\u043b\u0443\u0447\u0438\u0442\u044c \u043a\u043b\u044e\u0447 Web Proxy, "
    "\u043e\u0431\u0440\u0430\u0442\u0438\u0442\u0435\u0441\u044c \u043a \u0410\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0443 <b>Latinosaur</b>."
)


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    profiles = get_user_profiles(user.id, user.username)
    hostname = load_hostname()

    if not profiles:
        await update.message.reply_text(UNAUTHORIZED_TEXT, parse_mode="HTML")
        return

    if len(profiles) == 1:
        p = profiles[0]
        text = (
            f"\u26a1 \u0412\u0430\u0448 <b>Web Proxy</b> \u0448\u043b\u044e\u0437 \u0433\u043e\u0442\u043e\u0432!\n\n"
            f"{profile_block(p, hostname)}\n\n"
            f"\U0001f449 \u041d\u0430\u0436\u043c\u0438\u0442\u0435 \u043a\u043d\u043e\u043f\u043a\u0443 \u043d\u0438\u0436\u0435 \u0434\u043b\u044f \u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u044f \u0432 1 \u043a\u043b\u0438\u043a:"
        )
        connect_url = make_connect_url(hostname, p["secret"])
        keyboard = [[InlineKeyboardButton(
            "\U0001f680 \u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c Web Proxy (1 \u043a\u043b\u0438\u043a)",
            url=connect_url
        )]]
        reply_markup = InlineKeyboardMarkup(keyboard)
        await update.message.reply_text(text, reply_markup=reply_markup, parse_mode="HTML")
    else:
        await _send_profile_page(update, profiles, hostname, page=0)


async def _send_profile_page(update, profiles, hostname, page=0):
    total = len(profiles)
    total_pages = math.ceil(total / PROFILES_PER_PAGE)
    page = max(0, min(page, total_pages - 1))
    start = page * PROFILES_PER_PAGE
    end = start + PROFILES_PER_PAGE
    chunk = profiles[start:end]

    text = (
        f"\U0001f4cb <b>Web Proxy \u043f\u0440\u043e\u0444\u0438\u043b\u0438</b> "
        f"(\u0441\u0442\u0440. {page + 1}/{total_pages}):\n"
    )
    for p in chunk:
        text += f"\n{profile_block(p, hostname)}\n"

    keyboard = []
    for p in chunk:
        connect_url = make_connect_url(hostname, p["secret"])
        keyboard.append([InlineKeyboardButton(
            f"\U0001f680 \u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c {p['name']}",
            url=connect_url
        )])

    nav = []
    if page > 0:
        nav.append(InlineKeyboardButton("\u2b05 \u041d\u0430\u0437\u0430\u0434", callback_data=f"page:{page - 1}"))
    if page < total_pages - 1:
        nav.append(InlineKeyboardButton("\u0412\u043f\u0435\u0440\u0435\u0434 \u27a1", callback_data=f"page:{page + 1}"))
    if nav:
        keyboard.append(nav)

    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text(text, reply_markup=reply_markup, parse_mode="HTML")


async def callback_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = query.data
    if data.startswith("page:"):
        page = int(data.split(":")[1])
        user = query.from_user
        profiles = get_user_profiles(user.id, user.username)
        hostname = load_hostname()
        if not profiles:
            return

        total = len(profiles)
        total_pages = math.ceil(total / PROFILES_PER_PAGE)
        page = max(0, min(page, total_pages - 1))
        start = page * PROFILES_PER_PAGE
        end = start + PROFILES_PER_PAGE
        chunk = profiles[start:end]

        text = (
            f"\U0001f4cb <b>Web Proxy \u043f\u0440\u043e\u0444\u0438\u043b\u0438</b> "
            f"(\u0441\u0442\u0440. {page + 1}/{total_pages}):\n"
        )
        for p in chunk:
            text += f"\n{profile_block(p, hostname)}\n"

        keyboard = []
        for p in chunk:
            connect_url = make_connect_url(hostname, p["secret"])
            keyboard.append([InlineKeyboardButton(
                f"\U0001f680 \u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c {p['name']}",
                url=connect_url
            )])

        nav = []
        if page > 0:
            nav.append(InlineKeyboardButton("\u2b05 \u041d\u0430\u0437\u0430\u0434", callback_data=f"page:{page - 1}"))
        if page < total_pages - 1:
            nav.append(InlineKeyboardButton("\u0412\u043f\u0435\u0440\u0435\u0434 \u27a1", callback_data=f"page:{page + 1}"))
        if nav:
            keyboard.append(nav)

        reply_markup = InlineKeyboardMarkup(keyboard)
        await query.edit_message_text(text, reply_markup=reply_markup, parse_mode="HTML")


async def cmd_profiles(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    profiles = get_user_profiles(user.id, user.username)
    hostname = load_hostname()
    if not profiles:
        await update.message.reply_text(UNAUTHORIZED_TEXT, parse_mode="HTML")
        return

    if len(profiles) <= PROFILES_PER_PAGE:
        text = f"\U0001f4cb <b>Web Proxy \u043f\u0440\u043e\u0444\u0438\u043b\u0438:</b>\n"
        keyboard = []
        for p in profiles:
            text += f"\n{profile_block(p, hostname)}\n"
            connect_url = make_connect_url(hostname, p["secret"])
            keyboard.append([InlineKeyboardButton(
                f"\U0001f680 \u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c {p['name']}",
                url=connect_url
            )])
        reply_markup = InlineKeyboardMarkup(keyboard)
        await update.message.reply_text(text, reply_markup=reply_markup, parse_mode="HTML")
    else:
        await _send_profile_page(update, profiles, hostname, page=0)


async def cmd_config(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    profiles = get_user_profiles(user.id, user.username)
    hostname = load_hostname()
    if not profiles:
        await update.message.reply_text(UNAUTHORIZED_TEXT, parse_mode="HTML")
        return

    text = "\U0001f527 <b>\u0420\u0443\u0447\u043d\u0430\u044f \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430:</b>\n\n"
    text += (
        "\U0001f449 Telegram: \u041d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0438 \u2192 \u041f\u0440\u043e\u043a\u0441\u0438 \u2192 "
        "\u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u043f\u0440\u043e\u043a\u0441\u0438 \u2192 <b>WEB</b>\n\n"
    )
    for p in profiles:
        text += (
            f"<b>{p['name']}</b>\n"
            f"  Hostname: <code>{hostname}</code>\n"
            f"  Secret:   <code>{p['secret']}</code>\n\n"
        )
    await update.message.reply_text(text, parse_mode="HTML")


async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = (
        "<b>\U0001f4d6 \u041a\u043e\u043c\u0430\u043d\u0434\u044b:</b>\n\n"
        "/start - \u041f\u043e\u0434\u043a\u043b\u044e\u0447\u0438\u0442\u044c\u0441\u044f \u043a Web Proxy\n"
        "/profiles - \u0421\u043f\u0438\u0441\u043e\u043a \u043f\u0440\u043e\u0444\u0438\u043b\u0435\u0439\n"
        "/config - \u0420\u0443\u0447\u043d\u0430\u044f \u043d\u0430\u0441\u0442\u0440\u043e\u0439\u043a\u0430\n"
        "/help - \u041f\u043e\u043c\u043e\u0449\u044c\n\n"
        "\U0001f517 <b>Web Proxy</b> \u2014 \u043d\u043e\u0432\u044b\u0439 \u0442\u0440\u0430\u043d\u0441\u043f\u043e\u0440\u0442 Telegram. "
        "\u0422\u0440\u0430\u0444\u0438\u043a \u043c\u0430\u0441\u043a\u0438\u0440\u0443\u0435\u0442\u0441\u044f \u043f\u043e\u0434 HTTPS.\n\n"
        "\u0414\u043e\u0441\u0442\u0443\u043f \u0438\u043c\u0435\u044e\u0442 \u0442\u043e\u043b\u044c\u043a\u043e \u043d\u0430\u0437\u043d\u0430\u0447\u0435\u043d\u043d\u044b\u0435 \u043f\u043e\u043b\u044c\u0437\u043e\u0432\u0430\u0442\u0435\u043b\u0438. "
        "\u0414\u043b\u044f \u043f\u043e\u043b\u0443\u0447\u0435\u043d\u0438\u044f \u043a\u043b\u044e\u0447\u0430 \u043e\u0431\u0440\u0430\u0442\u0438\u0442\u0435\u0441\u044c \u043a \u0410\u0434\u043c\u0438\u043d\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0443 <b>Latinosaur</b>."
    )
    await update.message.reply_text(text, parse_mode="HTML")


def main():
    if not BOT_TOKEN:
        logger.error("TG_PROXY_BOT_TOKEN not set")
        return

    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("profiles", cmd_profiles))
    app.add_handler(CommandHandler("config", cmd_config))
    app.add_handler(CommandHandler("help", cmd_help))
    app.add_handler(CallbackQueryHandler(callback_handler, pattern=r"^page:"))

    logger.info("Bot started (WEB proxy, user-filtered)")
    app.run_polling()


if __name__ == "__main__":
    main()
