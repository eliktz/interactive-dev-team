# Telegram Setup Guide

This guide walks you through creating the Telegram bots and group needed to run
Interactive Dev Team.

## Overview

You need to create:
- **3 Telegram bots** (one per agent: Captain, CEO, UX Designer)
- **1 Telegram group** where all bots and humans collaborate
- **Bot tokens** and a **group chat ID** for your `.env` file

## Step 1: Create Telegram Bots via @BotFather

Open Telegram and search for [@BotFather](https://t.me/BotFather) (the official bot
for creating bots).

### Create the Captain Bot

1. Send `/newbot` to @BotFather
2. Choose a display name (e.g., `Captain Bob-T`)
3. Choose a username (must end in `bot`, e.g., `captain_bobt_bot`)
4. BotFather will reply with a token like:
   ```
   1234567890:ABCdefGhIjKlMnOpQrStUvWxYz
   ```
5. Save this token -- it goes in `CAPTAIN_TELEGRAM_TOKEN` in your `.env`

### Create the CEO Bot

1. Send `/newbot` to @BotFather again
2. Display name: e.g., `CEO Yefet`
3. Username: e.g., `ceo_yefet_bot`
4. Save the token for `CEO_GONORTH_TELEGRAM_TOKEN`

### Create the UX Designer Bot

1. Send `/newbot` to @BotFather again
2. Display name: e.g., `Hedva UX`
3. Username: e.g., `hedva_ux_bot`
4. Save the token for `UX_GONORTH_TELEGRAM_TOKEN`

## Step 2: Disable Privacy Mode for Captain

The Captain bot needs to see ALL messages in the group (not just messages that
@-mention it). By default, Telegram bots only see commands and @-mentions.

1. Send `/mybots` to @BotFather
2. Select the Captain bot
3. Choose **Bot Settings**
4. Choose **Group Privacy**
5. Choose **Disable**

BotFather will confirm: "Privacy mode is disabled for Captain Bob-T."

> **Important:** Only disable privacy mode for Captain. The CEO and UX Designer bots
> should keep privacy mode enabled (the default) -- they only need to see messages
> where they are @-mentioned.

## Step 3: (Optional) Set Bot Descriptions and Avatars

While still in @BotFather, you can set descriptions and profile photos for each bot:

1. Send `/mybots` and select a bot
2. **Edit Bot** > **Edit Description** -- set a short description
3. **Edit Bot** > **Edit About** -- set the "About" text shown in the bot's profile
4. **Edit Bot** > **Edit Botpic** -- upload a profile photo

Suggested descriptions:
- **Captain:** "War room triage router and scrum master"
- **CEO:** "Go-North CEO -- coordinates the team and tracks progress"
- **UX Designer:** "Go-North UX designer -- guards design quality"

## Step 4: Create a Telegram Group

1. Open Telegram and create a new group
2. Name it something like "Go-North War Room" (or your company name)
3. Add all 3 bots to the group:
   - Search for each bot by its username (e.g., `@captain_bobt_bot`)
   - Add them as members
4. Make all 3 bots **admins** of the group:
   - Tap the group name at the top
   - Go to **Members** or **Administrators**
   - For each bot: tap > **Promote to Admin**
   - Grant at minimum: **Send Messages**, **Delete Messages**

> **Why admin?** Bots need admin rights to reliably receive messages in groups and
> to send messages without restrictions.

## Step 5: Get the Group Chat ID

The group chat ID is a negative number (e.g., `-1001234567890`) that identifies your
Telegram group. You need it for `GONORTH_GROUP_ID` in `.env`.

### Method A: Use @userinfobot

1. Add [@userinfobot](https://t.me/userinfobot) to your group
2. It will immediately post a message with the group info, including the chat ID
3. Copy the chat ID (it will be a negative number)
4. Remove @userinfobot from the group (it was only needed for this step)

### Method B: Use the Telegram Bot API

Send a message in the group (any message), then call the bot API:

```bash
curl -s "https://api.telegram.org/bot<YOUR_CAPTAIN_TOKEN>/getUpdates" | python3 -m json.tool
```

Look for the `chat` object in the response:

```json
{
  "chat": {
    "id": -1001234567890,
    "title": "Go-North War Room",
    "type": "supergroup"
  }
}
```

The `id` value is your group chat ID.

### Method C: Use @RawDataBot

1. Add [@RawDataBot](https://t.me/RawDataBot) to your group
2. It will post a JSON dump including the chat ID
3. Copy the chat ID
4. Remove @RawDataBot from the group

## Step 6: Get Your Operator Telegram ID

The operator ID is your personal Telegram user ID. Agents can use it to send you
direct notifications. This is optional but recommended.

### Method A: Use @userinfobot

1. Open a direct chat with [@userinfobot](https://t.me/userinfobot)
2. Send any message (or just forward a message to it)
3. It will reply with your user ID (a positive number like `123456789`)

### Method B: Use @RawDataBot

1. Open a direct chat with [@RawDataBot](https://t.me/RawDataBot)
2. Send any message
3. It will reply with a JSON dump containing your user ID in `from.id`

## Step 7: Configure .env

Put all the values into your `.env` file:

```bash
# Telegram Bot Tokens
CAPTAIN_TELEGRAM_TOKEN=1234567890:ABCdefGhIjKlMnOpQrStUvWxYz
CEO_GONORTH_TELEGRAM_TOKEN=0987654321:ZyXwVuTsRqPoNmLkJiHgFeDcBa
UX_GONORTH_TELEGRAM_TOKEN=1122334455:AaBbCcDdEeFfGgHhIiJjKkLlMm

# Telegram Group
GONORTH_GROUP_ID=-1001234567890

# Your personal ID (optional)
OPERATOR_TELEGRAM_ID=123456789
```

## Verification

After starting the stack (`docker compose up -d`), verify each bot is connected:

1. Check the war-room logs:
   ```bash
   docker compose logs war-room | grep "Telegram"
   ```
   You should see messages like:
   ```
   [war-room] [captain] Telegram token written to ...
   [war-room] [ceo-gonorth] Telegram token written to ...
   [war-room] [ux-gonorth] Telegram token written to ...
   ```

2. Send a test message in your Telegram group. Captain should respond (since it sees
   all messages).

3. @-mention the CEO bot (e.g., `@ceo_yefet_bot hello`) -- it should respond.

4. @-mention the UX bot (e.g., `@hedva_ux_bot hello`) -- it should respond.

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Bot doesn't respond to any messages | Token is wrong or not set | Verify token in `.env` matches @BotFather output |
| Captain doesn't see messages without @-mention | Privacy mode is enabled | Go to @BotFather > `/mybots` > Captain > Bot Settings > Group Privacy > Disable |
| CEO/UX respond to messages they shouldn't | Privacy mode was disabled | Enable privacy mode for CEO and UX bots (should be the default) |
| "bot is not a member of the group" error | Bot was not added to group | Add the bot to the group and make it an admin |
| Group ID doesn't work | Copied wrong ID or wrong format | Must be a negative number; re-check with @userinfobot |
| Bot responds in DM but not in group | Bot is not an admin in the group | Promote the bot to admin in group settings |

## Security Notes

- **Never commit bot tokens to git.** The `.env` file is in `.gitignore`.
- **Rotate tokens** if compromised: go to @BotFather > `/mybots` > select bot >
  **API Token** > **Revoke current token**.
- **Restrict group access:** Make the Telegram group private (invite-only) so only
  your team can send messages to the agents.
- **OPERATOR_TELEGRAM_ID** controls who can receive DM notifications from agents.
  Only set this to your own user ID.
